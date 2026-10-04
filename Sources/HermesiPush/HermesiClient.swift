import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Settings for ``HermesiClient``.
public struct HermesiClientOptions: Sendable {
    /// The environment's public key, `hm_pk_...`. It is safe to ship in an app: on its own it grants nothing.
    public let publicKey: String
    /// The client API root, for example `https://api.example.com/v1/client`, without a trailing slash.
    public let apiBaseURL: String
    /// Returns a token that proves which subscriber this device belongs to. Your backend mints it with your
    /// secret key, so this calls your backend; the SDK never has the secret. It is called before every request,
    /// so return a cached token while it is still valid and fetch a new one when it is not.
    public let subscriberToken: @Sendable () async throws -> String
    public let timeout: TimeInterval

    public init(
        publicKey: String,
        apiBaseURL: String,
        timeout: TimeInterval = 15,
        subscriberToken: @escaping @Sendable () async throws -> String
    ) {
        self.publicKey = publicKey
        var base = apiBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        self.apiBaseURL = base
        self.timeout = timeout
        self.subscriberToken = subscriberToken
    }
}

/// One thing wrong with a request, as the API describes it.
public struct HermesiErrorDetail: Sendable, Equatable {
    public let field: String?
    public let issue: String?
}

/// Hermesi refused a request. Branch on ``code``, which is stable; ``message`` is for a developer and may change.
/// A failure to reach Hermesi at all is a `URLError` instead, which is worth retrying.
public struct HermesiAPIError: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: Int
    public let type: String
    public let code: String
    public let message: String
    public let requestId: String
    public let detail: [HermesiErrorDetail]

    /// True for a failure that asking again later can fix: a server error or rate limiting.
    public var isRetryable: Bool { status == 429 || status >= 500 }

    public var description: String { "HermesiAPIError(\(status) \(code): \(message))" }

    static func from(status: Int, body: Data) -> HermesiAPIError {
        let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = envelope?["error"] as? [String: Any]
        func text(_ key: String) -> String? {
            guard let value = error?[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let details = (error?["detail"] as? [[String: Any]] ?? []).map {
            HermesiErrorDetail(field: ($0["field"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               issue: ($0["issue"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return HermesiAPIError(
            status: status,
            // The API never sends this type, so a caller can tell the SDK reporting a response it could not read
            // from the server reporting a failure.
            type: text("type") ?? "sdk_error",
            code: text("code") ?? "unexpected_response",
            message: text("message") ?? "Hermesi request failed with status \(status).",
            requestId: text("request_id") ?? "",
            detail: details
        )
    }
}

/// What goes over the wire, so a test can stand in for the network.
public struct HTTPRequest: Sendable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    /// Sends the request and returns the response whatever its status. Throws if there is none.
    func execute(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// The default transport: `URLSession`, so the SDK brings no HTTP library of its own.
final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let timeout: TimeInterval
    private let protocolClasses: [AnyClass]?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// `protocolClasses` is a seam for tests, which answer requests without a network.
    init(timeout: TimeInterval, protocolClasses: [AnyClass]? = nil) {
        self.timeout = timeout
        self.protocolClasses = protocolClasses
    }

    // A redirect would carry the subscriber token to wherever it points.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        // `data(for:)` needs iOS 15; a continuation keeps the package at iOS 13.
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: HTTPResponse(status: http.statusCode, body: data ?? Data()))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }
}

/// The two calls a device registration makes. ``HermesiClient`` is the implementation; this is what the rest uses.
public protocol DeviceAPI: Sendable {
    /// Registers or refreshes this device's token. Registering the same token again is an update.
    func registerDevice(token: String, metadata: [String: Any]) async throws
    /// Removes a token. A token Hermesi does not have is not an error.
    func unregisterDevice(token: String) async throws
}

/// Talks to Hermesi's client API on behalf of one subscriber.
///
/// Every function is `async`. It throws ``HermesiAPIError`` when Hermesi refuses, and a `URLError` when it cannot be
/// reached.
public final class HermesiClient: DeviceAPI, @unchecked Sendable {
    private let options: HermesiClientOptions
    private let transport: HTTPTransport

    public init(options: HermesiClientOptions) {
        self.options = options
        self.transport = URLSessionTransport(timeout: options.timeout)
    }

    /// For tests: the same client over a transport of your own.
    public init(options: HermesiClientOptions, transport: HTTPTransport) {
        self.options = options
        self.transport = transport
    }

    public func registerDevice(token: String, metadata: [String: Any]) async throws {
        let body: [String: Any] = ["channel": "push", "identifier": token, "metadata": metadata]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        try await send(method: "POST", path: "/channels", body: data)
    }

    public func unregisterDevice(token: String) async throws {
        try await send(method: "DELETE", path: "/channels/push/\(Self.encodePathSegment(token))", body: nil)
    }

    private func send(method: String, path: String, body: Data?) async throws {
        var headers = [
            "Authorization": "Bearer \(options.publicKey)",
            "X-Hermesi-Subscriber-Token": try await options.subscriberToken(),
            "Accept": "application/json",
        ]
        if body != nil { headers["Content-Type"] = "application/json" }
        guard let url = URL(string: options.apiBaseURL + path) else { throw URLError(.badURL) }
        let response = try await transport.execute(HTTPRequest(method: method, url: url, headers: headers, body: body))
        guard (200...299).contains(response.status) else {
            throw HermesiAPIError.from(status: response.status, body: response.body)
        }
    }

    /// A path segment, not a query value: everything but unreserved characters is escaped, so a slash cannot
    /// escape the segment and a plus stays a plus.
    static func encodePathSegment(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
