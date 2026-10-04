import XCTest
@testable import HermesiPush

/// A notification's link comes from a template, so what a tap is allowed to open is decided here, not by whoever wrote
/// the template.
final class PushContentTests: XCTestCase {

    private func link(_ url: String?, schemes: Set<String> = []) -> URL? {
        PushContent(title: "t", body: "b", data: url.map { [PushContent.actionURLKey: $0] } ?? [:]).actionURL(deepLinkSchemes: schemes)
    }

    func testOpensWebLinks() {
        XCTAssertEqual(link("https://app.example.test/orders/1")?.absoluteString, "https://app.example.test/orders/1")
        XCTAssertEqual(link("http://app.example.test/x")?.absoluteString, "http://app.example.test/x")
    }

    func testReadsTheSchemeWithoutRegardToCase() {
        XCTAssertNotNil(link("HTTPS://app.example.test/x"))
    }

    func testOpensTheAppsOwnDeepLinksOnlyWhenTheAppListedTheScheme() {
        XCTAssertNil(link("myapp://orders/1"))
        XCTAssertEqual(link("myapp://orders/1", schemes: ["myapp"])?.absoluteString, "myapp://orders/1")
        XCTAssertNotNil(link("myapp://orders/1", schemes: ["MyApp"]))
    }

    func testRefusesSchemesThatAreNotLinks() {
        for url in [
            "javascript:alert(1)",
            "file:///private/var/secret",
            "data:text/html,<script>1</script>",
            "blob:https://x/1",
            "ftp://x/y",
            "tel:+237670000001",
            "sms:+237670000001",
            "prefs:root=General",
            "app-settings:",
        ] {
            XCTAssertNil(link(url, schemes: ["myapp"]), "\(url) must not open")
        }
    }

    func testRefusesWhatIsNotAURLAtAll() {
        XCTAssertNil(link(nil))
        XCTAssertNil(link(""))
        XCTAssertNil(link("   "))
        XCTAssertNil(link("/orders/1"))
        XCTAssertNil(link("orders/1"))
        // Newer Foundation percent-encodes a space instead of failing; a link nobody wrote is not repaired into one.
        XCTAssertNil(link("https://example.test/with space"))
        XCTAssertNil(link("https://example.test/with\nnewline"))
    }

    func testReadsTheAlertAndTheDataOutOfAnAPNsPayload() {
        let content = PushContent(userInfo: [
            "aps": ["alert": ["title": "Shipped", "body": "Tomorrow"], "sound": "default"],
            "action_url": "https://app.example.test/o/1",
            "order": "4821",
            "badge_count": 3,
        ])

        XCTAssertEqual(content.title, "Shipped")
        XCTAssertEqual(content.body, "Tomorrow")
        XCTAssertEqual(content.data, ["action_url": "https://app.example.test/o/1", "order": "4821"], "only strings, and never aps")
    }

    func testReadsAnAlertThatIsJustAString() {
        let content = PushContent(userInfo: ["aps": ["alert": "Hello"]])

        XCTAssertNil(content.title)
        XCTAssertEqual(content.body, "Hello")
    }

    func testReadsAPayloadWithNoApsAtAll() {
        let content = PushContent(userInfo: ["order": "1"])

        XCTAssertNil(content.title)
        XCTAssertNil(content.body)
        XCTAssertEqual(content.data, ["order": "1"])
    }
}

final class PushTokenTests: XCTestCase {

    func testAnAPNsTokenIsLowercaseHexadecimalWithItsLeadingZeros() {
        XCTAssertEqual(PushToken.apns(Data([0x0a, 0xff, 0x00, 0x1b])).identifier, "0aff001b")
        XCTAssertEqual(PushToken.apns(Data(repeating: 0xab, count: 32)).identifier, String(repeating: "ab", count: 32))
    }

    func testAFirebaseTokenIsPassedThroughUnchanged() {
        XCTAssertEqual(PushToken.fcm("fcm:APA91b-token_1").identifier, "fcm:APA91b-token_1")
    }

    func testEachTokenNamesItsTransport() {
        XCTAssertEqual(PushToken.apns(Data([1])).transport, "apns")
        XCTAssertEqual(PushToken.fcm("x").transport, "fcm")
    }
}

final class DeviceMetadataTests: XCTestCase {

    func testDescribesTheDevice() {
        let metadata = DeviceMetadata.build(transport: "apns", osVersion: "17.4.1", appVersion: "3.2.1", extra: [:])

        XCTAssertEqual(metadata["platform"] as? String, "ios")
        XCTAssertEqual(metadata["transport"] as? String, "apns")
        XCTAssertEqual(metadata["os_version"] as? String, "17.4.1")
        XCTAssertEqual(metadata["app_version"] as? String, "3.2.1")
        XCTAssertEqual(metadata["sdk"] as? String, "hermesi-ios/\(DeviceMetadata.sdkVersion)")
    }

    func testKeepsWhatTheAppAdds() {
        XCTAssertEqual(DeviceMetadata.build(transport: "fcm", osVersion: "17", appVersion: nil, extra: ["plan": "pro"])["plan"] as? String, "pro")
    }

    func testDoesNotLetTheAppChangeTheTransportOrThePlatform() {
        // An app that said `apns` for a Firebase token would send it to a provider that cannot reach it, and each
        // refusal would read as a dead device.
        let metadata = DeviceMetadata.build(transport: "fcm", osVersion: "17", appVersion: nil, extra: ["transport": "apns", "platform": "android"])

        XCTAssertEqual(metadata["transport"] as? String, "fcm")
        XCTAssertEqual(metadata["platform"] as? String, "ios")
    }

    func testLeavesOutAnAppVersionItDoesNotHave() {
        XCTAssertNil(DeviceMetadata.build(transport: "apns", osVersion: "17", appVersion: nil, extra: [:])["app_version"])
    }
}
