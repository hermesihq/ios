import Foundation
@testable import HermesiPush

/// Records what the registrar asks of the API, and can be told to fail or to wait.
final class FakeAPI: DeviceAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _metadata: [[String: Any]] = []
    var failRegister: Error?
    var failUnregister: Error?
    /// When set, `registerDevice` waits for it before returning.
    var gate: AsyncGate?

    var calls: [String] { lock.withLock { _calls } }
    var metadata: [[String: Any]] { lock.withLock { _metadata } }
    func clear() { lock.withLock { _calls.removeAll(); _metadata.removeAll() } }

    func registerDevice(token: String, metadata: [String: Any]) async throws {
        lock.withLock { _calls.append("register:\(token)") }
        await gate?.wait()
        if let failRegister { throw failRegister }
        lock.withLock { _metadata.append(metadata) }
    }

    func unregisterDevice(token: String) async throws {
        lock.withLock { _calls.append("unregister:\(token)") }
        if let failUnregister { throw failUnregister }
    }
}

final class InMemoryStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _token: String?
    private var _metadata: [String: Any] = [:]
    init(token: String? = nil) { _token = token }
    func token() -> String? { lock.withLock { _token } }
    func setToken(_ token: String?) { lock.withLock { _token = token } }
    func metadata() -> [String: Any] { lock.withLock { _metadata } }
    func setMetadata(_ metadata: [String: Any]) { lock.withLock { _metadata = metadata } }
}

/// One-shot latch: callers of `wait` block until `open` is called.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// A transport that records requests and answers from a queue.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private var responses: [Result<HTTPResponse, Error>]

    init(_ responses: [Result<HTTPResponse, Error>]) { self.responses = responses }

    var requests: [HTTPRequest] { lock.withLock { _requests } }

    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        let next: Result<HTTPResponse, Error> = lock.withLock {
            _requests.append(request)
            return responses.isEmpty ? .success(HTTPResponse(status: 200, body: Data("{}".utf8))) : responses.removeFirst()
        }
        return try next.get()
    }
}

struct TestError: Error, Equatable { let name: String }

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
