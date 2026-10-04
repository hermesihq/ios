import XCTest
@testable import HermesiPush

/// The public facade over a fake API and an in-memory store, plus the `UserDefaults` store the app really gets.
final class HermesiPushTests: XCTestCase {

    private let api = FakeAPI()
    private let store = InMemoryStore()

    private func push(options: HermesiPushOptions = HermesiPushOptions()) -> HermesiPush {
        HermesiPush(api: api, options: options, store: store, onWarning: { _, _ in })
    }

    func testRegistersAnAPNsDeviceByItsHexTokenWithTheApnsTransport() async throws {
        try await push().register(.apns(Data([0x0a, 0xff])), metadata: ["plan": "pro", "transport": "fcm"])

        XCTAssertEqual(api.calls, ["register:0aff"])
        let metadata = try XCTUnwrap(api.metadata.first)
        XCTAssertEqual(metadata["platform"] as? String, "ios")
        XCTAssertEqual(metadata["transport"] as? String, "apns", "the token decides the transport, not the app")
        XCTAssertEqual(metadata["plan"] as? String, "pro")
    }

    func testRegistersAFirebaseDeviceWithTheFcmTransport() async throws {
        try await push().register(.fcm("fcm-token-1"))

        XCTAssertEqual(api.calls, ["register:fcm-token-1"])
        XCTAssertEqual(api.metadata.first?["transport"] as? String, "fcm")
    }

    func testATokenThatChangesIsRegisteredWithTheMetadataTheDeviceRegisteredWith() async throws {
        let push = push()
        try await push.register(.apns(Data([1])), metadata: ["plan": "pro"])
        api.clear()

        let handled = try await push.tokenDidChange(.apns(Data([2])))

        XCTAssertTrue(handled)
        XCTAssertEqual(api.calls, ["register:02", "unregister:01"])
        XCTAssertEqual(api.metadata.first?["plan"] as? String, "pro")
    }

    func testATokenThatChangesBeforeTheDeviceWasRegisteredIsIgnored() async throws {
        let push = push()

        let handled = try await push.tokenDidChange(.apns(Data([2])))

        XCTAssertFalse(handled)
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertFalse(push.isRegistered)
    }

    func testUnregisteringRemovesTheDevice() async throws {
        let push = push()
        try await push.register(.apns(Data([1])))
        XCTAssertTrue(push.isRegistered)

        try await push.unregister()

        XCTAssertEqual(api.calls, ["register:01", "unregister:01"])
        XCTAssertFalse(push.isRegistered)
    }

    func testReadsTheLinkOutOfAPayloadAndHonoursTheAppsSchemes() {
        let userInfo: [AnyHashable: Any] = ["action_url": "myapp://orders/1"]

        XCTAssertNil(push().actionURL(userInfo: userInfo))
        XCTAssertEqual(push(options: HermesiPushOptions(deepLinkSchemes: ["myapp"])).actionURL(userInfo: userInfo)?.absoluteString, "myapp://orders/1")
        XCTAssertNil(push(options: HermesiPushOptions(deepLinkSchemes: ["myapp"])).actionURL(userInfo: ["action_url": "javascript:alert(1)"]))
    }

    func testTheDefaultStoreKeepsTheTokenAndTheMetadataAcrossInstances() throws {
        let suite = "hermesi-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = UserDefaultsTokenStore(defaults: defaults)
        first.setToken("t1")
        first.setMetadata(["plan": "pro", "nested": ["a": 1]])

        // A new process: the same store, read back.
        let second = UserDefaultsTokenStore(defaults: defaults)
        XCTAssertEqual(second.token(), "t1")
        XCTAssertEqual(second.metadata()["plan"] as? String, "pro")
        XCTAssertEqual((second.metadata()["nested"] as? [String: Int])?["a"], 1)

        second.setToken(nil)
        XCTAssertNil(UserDefaultsTokenStore(defaults: defaults).token())
    }

    func testTheDefaultStoreToleratesMetadataThatCannotBeSerialised() throws {
        let suite = "hermesi-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsTokenStore(defaults: defaults)

        store.setMetadata(["when": Date()])

        XCTAssertTrue(store.metadata().isEmpty)
    }
}
