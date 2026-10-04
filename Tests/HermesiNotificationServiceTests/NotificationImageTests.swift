import XCTest
@testable import HermesiNotificationService

/// Where the picture's URL comes from, and which URLs are accepted. The URL comes from a template and is fetched on the
/// person's device, so what counts as a URL here is decided by the SDK.
final class NotificationImageTests: XCTestCase {

    func testReadsTheURLHermesiPutsInTheAPNsPayload() {
        XCTAssertEqual(
            NotificationImage.url(in: ["aps": ["alert": "x"], "image_url": "https://cdn.example.test/a.png"])?.absoluteString,
            "https://cdn.example.test/a.png"
        )
    }

    func testReadsTheURLFirebasePutsInTheAPNsPayload() {
        XCTAssertEqual(
            NotificationImage.url(in: ["fcm_options": ["image": "https://cdn.example.test/b.jpg"]])?.absoluteString,
            "https://cdn.example.test/b.jpg"
        )
    }

    func testPrefersHermesisKeyWhenBothArePresent() {
        let userInfo: [AnyHashable: Any] = ["image_url": "https://a.example.test/1.png", "fcm_options": ["image": "https://b.example.test/2.png"]]

        XCTAssertEqual(NotificationImage.url(in: userInfo)?.host, "a.example.test")
    }

    func testFallsBackToTheOtherKeyWhenTheFirstIsNotUsable() {
        let userInfo: [AnyHashable: Any] = ["image_url": "http://insecure.example.test/1.png", "fcm_options": ["image": "https://b.example.test/2.png"]]

        XCTAssertEqual(NotificationImage.url(in: userInfo)?.host, "b.example.test")
    }

    func testAcceptsOnlyHTTPS() {
        for url in [
            "http://cdn.example.test/a.png",
            "file:///private/var/secret.png",
            "data:image/png;base64,AAAA",
            "ftp://cdn.example.test/a.png",
            "javascript:alert(1)",
            "//cdn.example.test/a.png",
            "cdn.example.test/a.png",
        ] {
            XCTAssertNil(NotificationImage.url(in: ["image_url": url]), "\(url) must not be fetched")
        }
    }

    func testReadsTheSchemeWithoutRegardToCase() {
        XCTAssertNotNil(NotificationImage.url(in: ["image_url": "HTTPS://cdn.example.test/a.png"]))
    }

    func testRefusesWhatIsNotAURLAtAll() {
        for raw in ["", "   ", "https://", "https://exa mple.test/a.png", "https://example.test/a\nb.png"] {
            XCTAssertNil(NotificationImage.url(in: ["image_url": raw]), "\(raw.debugDescription) must not be fetched")
        }
    }

    func testIgnoresValuesOfTheWrongType() {
        XCTAssertNil(NotificationImage.url(in: ["image_url": 7]))
        XCTAssertNil(NotificationImage.url(in: ["fcm_options": "https://cdn.example.test/a.png"]))
        XCTAssertNil(NotificationImage.url(in: ["fcm_options": ["image": 7]]))
        XCTAssertNil(NotificationImage.url(in: [:]))
    }
}
