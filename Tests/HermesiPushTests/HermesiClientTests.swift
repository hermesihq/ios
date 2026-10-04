import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HermesiPush

/// The calls as they go on the wire (through a fake transport), and the default `URLSession` transport through a
/// `URLProtocol` stub, because the redirect rule lives there.
final class HermesiClientTests: XCTestCase {

    private func client(
        _ transport: FakeTransport,
        base: String = "https://hermesi.example.test/v1/client",
        token: @escaping @Sendable () async throws -> String = { "st_1" }
    ) -> HermesiClient {
        HermesiClient(options: HermesiClientOptions(publicKey: "hm_pk_test", apiBaseURL: base, subscriberToken: token), transport: transport)
    }

    private func ok() -> Result<HTTPResponse, Error> { .success(HTTPResponse(status: 200, body: Data("{\"id\":\"sch_1\"}".utf8))) }

    private func refusal(_ status: Int, code: String = "invalid_device_registration", type: String = "validation_error") -> Result<HTTPResponse, Error> {
        let body = "{\"error\":{\"type\":\"\(type)\",\"code\":\"\(code)\",\"message\":\"Nope.\",\"request_id\":\"req_1\",\"detail\":[{\"field\":\"identifier\",\"issue\":\"bad\"}]}}"
        return .success(HTTPResponse(status: status, body: Data(body.utf8)))
    }

    func testRegistersADeviceAsAPushChannelWithItsMetadata() async throws {
        let transport = FakeTransport([ok()])

        try await client(transport).registerDevice(token: "apns-token", metadata: ["platform": "ios", "nested": ["a": 1]])

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://hermesi.example.test/v1/client/channels")
        XCTAssertEqual(request.headers["Authorization"], "Bearer hm_pk_test")
        XCTAssertEqual(request.headers["X-Hermesi-Subscriber-Token"], "st_1")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["channel"] as? String, "push")
        XCTAssertEqual(body["identifier"] as? String, "apns-token")
        let metadata = try XCTUnwrap(body["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["platform"] as? String, "ios")
        XCTAssertEqual((metadata["nested"] as? [String: Int])?["a"], 1)
    }

    func testRemovesADeviceByTokenWithThePathEncoded() async throws {
        let transport = FakeTransport([.success(HTTPResponse(status: 204, body: Data()))])

        try await client(transport).unregisterDevice(token: "tok en/with:odd+chars")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, "DELETE")
        // A path segment: a space is %20, a plus is %2B, and a slash cannot escape the segment.
        XCTAssertEqual(request.url.absoluteString, "https://hermesi.example.test/v1/client/channels/push/tok%20en%2Fwith%3Aodd%2Bchars")
        XCTAssertNil(request.headers["Content-Type"], "a DELETE has no body")
        XCTAssertNil(request.body)
    }

    func testAsksForASubscriberTokenOnEveryRequest() async throws {
        let counter = Counter()
        let transport = FakeTransport([ok(), .success(HTTPResponse(status: 204, body: Data()))])
        let client = client(transport) { "st_\(await counter.next())" }

        try await client.registerDevice(token: "t", metadata: [:])
        try await client.unregisterDevice(token: "t")

        XCTAssertEqual(transport.requests.map { $0.headers["X-Hermesi-Subscriber-Token"] }, ["st_1", "st_2"])
    }

    func testToleratesATrailingSlashOnTheBaseURL() async throws {
        let transport = FakeTransport([ok()])

        try await client(transport, base: "https://hermesi.example.test/v1/client//").registerDevice(token: "t", metadata: [:])

        XCTAssertEqual(transport.requests.first?.url.absoluteString, "https://hermesi.example.test/v1/client/channels")
    }

    func testTurnsARefusalIntoAnErrorCarryingWhatTheAPISaid() async throws {
        let transport = FakeTransport([refusal(422)])

        do {
            try await client(transport).registerDevice(token: "t", metadata: [:])
            XCTFail("expected a HermesiAPIError")
        } catch let error as HermesiAPIError {
            XCTAssertEqual(error.status, 422)
            XCTAssertEqual(error.type, "validation_error")
            XCTAssertEqual(error.code, "invalid_device_registration")
            XCTAssertEqual(error.message, "Nope.")
            XCTAssertEqual(error.requestId, "req_1")
            XCTAssertEqual(error.detail, [HermesiErrorDetail(field: "identifier", issue: "bad")])
            XCTAssertFalse(error.isRetryable)
        }
    }

    func testMarksServerErrorsAndRateLimitingAsRetryable() async throws {
        for status in [429, 500, 503] {
            let transport = FakeTransport([refusal(status, code: "unavailable", type: "internal_error")])
            do {
                try await client(transport).registerDevice(token: "t", metadata: [:])
                XCTFail("expected a HermesiAPIError")
            } catch let error as HermesiAPIError {
                XCTAssertTrue(error.isRetryable, "\(status) should be retryable")
            }
        }
    }

    func testSaysSoWhenARefusalIsNotInTheEnvelopeTheAPIUses() async throws {
        let transport = FakeTransport([.success(HTTPResponse(status: 502, body: Data("<html>Bad gateway</html>".utf8)))])

        do {
            try await client(transport).registerDevice(token: "t", metadata: [:])
            XCTFail("expected a HermesiAPIError")
        } catch let error as HermesiAPIError {
            // The API never sends these, so a caller can tell the SDK failing to read an answer from the server
            // reporting a failure.
            XCTAssertEqual(error.type, "sdk_error")
            XCTAssertEqual(error.code, "unexpected_response")
            XCTAssertEqual(error.status, 502)
            XCTAssertTrue(error.isRetryable)
        }
    }

    func testDoesNotSendTheRequestWhenNoSubscriberTokenIsAvailable() async throws {
        let transport = FakeTransport([ok()])

        do {
            try await client(transport) { throw TestError(name: "signed out") }.registerDevice(token: "t", metadata: [:])
            XCTFail("expected an error")
        } catch let error as TestError {
            XCTAssertEqual(error, TestError(name: "signed out"))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAFailureToReachHermesiIsTheTransportsOwnError() async throws {
        let transport = FakeTransport([.failure(URLError(.notConnectedToInternet))])

        do {
            try await client(transport).registerDevice(token: "t", metadata: [:])
            XCTFail("expected a URLError")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }

    // MARK: - the default transport

    func testTheDefaultTransportRefusesToFollowARedirectWithTheSubscriberTokenInIt() throws {
        let transport = URLSessionTransport(timeout: 5)
        let task = URLSession.shared.dataTask(with: URL(string: "https://hermesi.example.test/v1/client/channels")!)
        let redirect = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://hermesi.example.test/v1/client/channels")!,
            statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://elsewhere.example.test/"]
        ))
        var followed: URLRequest?? = .some(URLRequest(url: URL(string: "https://unset.example.test/")!))

        // Called as URLSession calls it when a server answers with a redirect. Answering nil is what stops it: the
        // request, with its headers, is never sent to the new location. (A `URLProtocol` stub cannot drive a real
        // redirect on Linux, so the delegate's answer is checked directly.)
        transport.urlSession(
            URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: URL(string: "https://elsewhere.example.test/")!)
        ) { followed = .some($0) }

        XCTAssertNotNil(followed)
        XCTAssertNil(followed!, "a redirect must not be followed")
    }

    func testTheDefaultTransportSendsTheMethodHeadersAndBody() async throws {
        StubProtocol.reset()
        StubProtocol.handler = { _ in .response(status: 200, body: "{}") }
        let transport = URLSessionTransport(timeout: 5, protocolClasses: [StubProtocol.self])

        _ = try await transport.execute(
            HTTPRequest(method: "POST", url: URL(string: "https://hermesi.example.test/x")!, headers: ["X-Hermesi-Subscriber-Token": "st_1"], body: Data("{\"a\":1}".utf8))
        )

        let seen = try XCTUnwrap(StubProtocol.seen.first)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.headers["X-Hermesi-Subscriber-Token"], "st_1")
        XCTAssertEqual(seen.body, "{\"a\":1}")
    }
}

private actor Counter {
    private var value = 0
    func next() -> Int { value += 1; return value }
}

/// A `URLProtocol` that answers from a closure and remembers what it was asked.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case response(status: Int, body: String)
        case redirect(to: String)
    }

    struct Seen { let method: String; let headers: [String: String]; let body: String }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: ((URLRequest) -> Reply)?
        var paths: [String] = []
        var seen: [Seen] = []
    }

    private static let state = State()

    static var handler: ((URLRequest) -> Reply)? {
        get { state.lock.withLock { state.handler } }
        set { state.lock.withLock { state.handler = newValue } }
    }
    static var paths: [String] { state.lock.withLock { state.paths } }
    static var seen: [Seen] { state.lock.withLock { state.seen } }
    static func reset() { state.lock.withLock { state.handler = nil; state.paths = []; state.seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var bodyText = ""
        if let body = request.httpBody {
            bodyText = String(decoding: body, as: UTF8.self)
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            bodyText = String(decoding: data, as: UTF8.self)
        }
        Self.state.lock.withLock {
            Self.state.paths.append(request.url?.path ?? "")
            Self.state.seen.append(Seen(method: request.httpMethod ?? "", headers: request.allHTTPHeaderFields ?? [:], body: bodyText))
        }
        guard let url = request.url, let reply = Self.handler?(request) else { return client?.urlProtocol(self, didFailWithError: URLError(.unknown)) ?? () }
        switch reply {
        case .response(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let location):
            let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
        }
    }

    override func stopLoading() {}
}
