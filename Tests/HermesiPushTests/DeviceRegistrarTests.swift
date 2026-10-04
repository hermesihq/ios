import XCTest
@testable import HermesiPush

/// The rule for a rotated token, and for what a failure at each step leaves behind. Everything here is a fake, so what
/// is checked is the order of the calls and the state afterwards, which is the whole of this class.
final class DeviceRegistrarTests: XCTestCase {

    private let api = FakeAPI()
    private let store = InMemoryStore()
    private let warnings = Box<[String]>([])

    private func registrar() -> DeviceRegistrar {
        let warnings = self.warnings
        return DeviceRegistrar(
            api: api,
            store: store,
            metadata: { transport, extras in extras.merging(["platform": "ios", "transport": transport]) { _, new in new } },
            onWarning: { message, _ in warnings.mutate { $0.append(message) } }
        )
    }

    func testRegistersTheTokenAndRemembersIt() async throws {
        try await registrar().register(token: "t1", transport: "apns", metadata: ["plan": "pro"])

        XCTAssertEqual(api.calls, ["register:t1"])
        XCTAssertEqual(store.token(), "t1")
        XCTAssertEqual(api.metadata.first?["transport"] as? String, "apns")
        XCTAssertEqual(api.metadata.first?["plan"] as? String, "pro")
    }

    func testRegisteringTheSameTokenAgainIsAnUpdateAndRetiresNothing() async throws {
        let registrar = registrar()
        try await registrar.register(token: "t1", transport: "apns", metadata: [:])
        try await registrar.register(token: "t1", transport: "apns", metadata: [:])

        XCTAssertEqual(api.calls, ["register:t1", "register:t1"])
    }

    func testARotatedTokenIsRegisteredBeforeTheOldOneIsRemoved() async throws {
        let registrar = registrar()
        try await registrar.register(token: "t1", transport: "apns", metadata: [:])
        api.clear()

        let refreshed = try await registrar.refresh(token: "t2", transport: "apns")

        XCTAssertTrue(refreshed)
        // New first: a failure in between leaves the device registered under one token, never none.
        XCTAssertEqual(api.calls, ["register:t2", "unregister:t1"])
        XCTAssertEqual(store.token(), "t2")
    }

    func testARefreshRegistersWithTheMetadataTheDeviceRegisteredWithAndTheNewTokensTransport() async throws {
        let registrar = registrar()
        try await registrar.register(token: "t1", transport: "apns", metadata: ["plan": "pro"])
        api.clear()

        // The app moved from Apple direct to Firebase: the plan survives and the transport follows the token.
        try await registrar.refresh(token: "fcm-token", transport: "fcm")

        XCTAssertEqual(api.metadata.first?["plan"] as? String, "pro")
        XCTAssertEqual(api.metadata.first?["transport"] as? String, "fcm")
    }

    func testARotationThatFailsToRegisterLeavesTheOldTokenAndRemovesNothing() async throws {
        let registrar = registrar()
        try await registrar.register(token: "t1", transport: "apns", metadata: [:])
        api.clear()
        api.failRegister = URLError(.notConnectedToInternet)

        do {
            _ = try await registrar.refresh(token: "t2", transport: "apns")
            XCTFail("expected an error")
        } catch {}

        XCTAssertEqual(api.calls, ["register:t2"])
        XCTAssertEqual(store.token(), "t1")
    }

    func testFailingToRemoveTheOldTokenIsAWarningNotAFailure() async throws {
        let registrar = registrar()
        try await registrar.register(token: "t1", transport: "apns", metadata: [:])
        api.failUnregister = URLError(.notConnectedToInternet)

        let refreshed = try await registrar.refresh(token: "t2", transport: "apns")

        XCTAssertTrue(refreshed)
        XCTAssertEqual(store.token(), "t2")
        XCTAssertEqual(warnings.value.count, 1)
    }

    func testCancellationWhileRemovingTheOldTokenIsNotSwallowed() async throws {
        let registrar = registrar()
        try await registrar.register(token: "t1", transport: "apns", metadata: [:])
        api.failUnregister = CancellationError()

        do {
            _ = try await registrar.refresh(token: "t2", transport: "apns")
            XCTFail("expected a CancellationError")
        } catch is CancellationError {}
        XCTAssertTrue(warnings.value.isEmpty)
    }

    func testARefreshBeforeTheDeviceWasEverRegisteredDoesNothing() async throws {
        let refreshed = try await registrar().refresh(token: "t2", transport: "apns")

        XCTAssertFalse(refreshed, "there is no subscriber yet to register it for")
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertNil(store.token())
    }

    func testARegistrationThatFailsRemembersNothing() async throws {
        api.failRegister = HermesiAPIError(status: 401, type: "authentication_error", code: "invalid_token", message: "x", requestId: "", detail: [])
        let registrar = registrar()

        do {
            try await registrar.register(token: "t1", transport: "apns", metadata: [:])
            XCTFail("expected an error")
        } catch is HermesiAPIError {}

        XCTAssertNil(store.token())
        XCTAssertFalse(registrar.isRegistered)
    }

    func testUnregisteringTellsHermesiThenForgets() async throws {
        let registrar = registrar()
        try await registrar.register(token: "t1", transport: "apns", metadata: [:])
        api.clear()

        try await registrar.unregister()

        XCTAssertEqual(api.calls, ["unregister:t1"])
        XCTAssertNil(store.token())
        XCTAssertFalse(registrar.isRegistered)
    }

    func testUnregisteringWhenHermesiCannotBeToldChangesNothing() async throws {
        let registrar = registrar()
        try await registrar.register(token: "t1", transport: "apns", metadata: [:])
        api.failUnregister = URLError(.notConnectedToInternet)

        do {
            try await registrar.unregister()
            XCTFail("expected an error")
        } catch is URLError {}

        XCTAssertEqual(store.token(), "t1", "a repeat of the call can still remove it")
    }

    func testUnregisteringADeviceThatWasNeverRegisteredDoesNothing() async throws {
        try await registrar().unregister()

        XCTAssertTrue(api.calls.isEmpty)
    }

    func testARefreshArrivingMidRegistrationWaitsForItAndSeesItsToken() async throws {
        let registrar = registrar()
        let gate = AsyncGate()
        api.gate = gate

        let first = Task { try await registrar.register(token: "t1", transport: "apns", metadata: [:]) }
        try await waitUntil { self.api.calls == ["register:t1"] }
        let second = Task { try await registrar.refresh(token: "t2", transport: "apns") }
        // Give the refresh every chance to start; it must not.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(api.calls, ["register:t1"], "the refresh must not start until the registration is done")

        api.gate = nil
        await gate.open()
        try await first.value
        _ = try await second.value

        // The refresh saw t1 as the registered token, so it retired it: no interleaving, no lost token.
        XCTAssertEqual(api.calls, ["register:t1", "register:t2", "unregister:t1"])
        XCTAssertEqual(store.token(), "t2")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func mutate(_ change: (inout T) -> Void) { lock.withLock { change(&_value) } }
}
