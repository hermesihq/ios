import Foundation

/// Remembers the token that was registered, across launches.
public protocol TokenStore: Sendable {
    func token() -> String?
    func setToken(_ token: String?)
    /// The metadata the app registered the device with, so a token that changes in a fresh process is registered with
    /// the same metadata.
    func metadata() -> [String: Any]
    func setMetadata(_ metadata: [String: Any])
}

/// Waits its turn. Swift actors are re-entrant across `await`, so an actor alone would let a token refresh run in
/// the middle of a registration; this is what stops that.
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func withLock<T>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        do {
            let result = try await body()
            unlock()
            return result
        } catch {
            unlock()
            throw error
        }
    }
}

/// Keeps this device registered with Hermesi as its push token changes.
///
/// The one thing it adds over calling the API is the rule for a rotated token. APNs and Firebase replace a device's
/// token from time to time, and the old one stops working. Registering the new token first and removing the old one
/// second means a failure in between leaves the device registered under at least one token, and never under none. A
/// failure to remove the old one is reported through `onWarning` and does not fail the call, because Hermesi removes a
/// token the push service reports as dead the next time it tries to send to it.
///
/// Calls are serialised, so a refresh arriving while `register` is in flight cannot interleave with it.
public final class DeviceRegistrar: @unchecked Sendable {
    private let api: DeviceAPI
    private let store: TokenStore
    private let metadataFor: @Sendable (_ transport: String, _ extras: [String: Any]) -> [String: Any]
    private let onWarning: @Sendable (String, Error) -> Void
    private let lock = AsyncLock()

    public init(
        api: DeviceAPI,
        store: TokenStore,
        metadata: @escaping @Sendable (_ transport: String, _ extras: [String: Any]) -> [String: Any],
        onWarning: @escaping @Sendable (String, Error) -> Void = { _, _ in }
    ) {
        self.api = api
        self.store = store
        self.metadataFor = metadata
        self.onWarning = onWarning
    }

    /// True if this device has been registered and not unregistered since.
    public var isRegistered: Bool { store.token() != nil }

    /// Registers `token`, and retires the previous one if it changed. Safe to call on every launch: registering a token
    /// Hermesi already has is an update, and it also reactivates a device Hermesi had marked invalid. `transport` is
    /// the road the token came from, and `metadata` is what the app adds to the device.
    public func register(token: String, transport: String, metadata: [String: Any]) async throws {
        try await lock.withLock {
            self.store.setMetadata(metadata)
            try await self.registerAndRetire(token: token, transport: transport, extras: metadata)
        }
    }

    /// For the token-changed callback. Does nothing, and returns false, if this device was never registered: there is
    /// no subscriber to register it for until the person has signed in, and `register` will do it then.
    @discardableResult
    public func refresh(token: String, transport: String) async throws -> Bool {
        try await lock.withLock {
            guard self.store.token() != nil else { return false }
            try await self.registerAndRetire(token: token, transport: transport, extras: self.store.metadata())
            return true
        }
    }

    /// Removes this device from Hermesi. If Hermesi cannot be told, nothing changes and the failure is thrown, so the
    /// call can be repeated.
    public func unregister() async throws {
        try await lock.withLock {
            guard let token = self.store.token() else { return }
            try await self.api.unregisterDevice(token: token)
            self.store.setToken(nil)
        }
    }

    private func registerAndRetire(token: String, transport: String, extras: [String: Any]) async throws {
        try await api.registerDevice(token: token, metadata: metadataFor(transport, extras))
        let previous = store.token()
        store.setToken(token)
        if let previous, previous != token {
            do {
                try await api.unregisterDevice(token: previous)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onWarning("Could not remove the previous push token; Hermesi will drop it when the push service reports it dead.", error)
            }
        }
    }
}
