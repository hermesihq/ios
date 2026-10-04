#if canImport(UserNotifications)
import UserNotifications
import XCTest
@testable import HermesiPush

/// What the notification delegate decides. The delegate itself needs UIKit and a real notification, which a test cannot
/// build; these run on macOS and in the iOS simulator.
final class NotificationHandlingTests: XCTestCase {

    private func push(schemes: Set<String> = []) -> HermesiPush {
        HermesiPush(api: FakeAPI(), options: HermesiPushOptions(deepLinkSchemes: schemes), store: InMemoryStore(), onWarning: { _, _ in })
    }

    func testShowsANotificationInTheForegroundWhenTheAppAsksFor() {
        let options = NotificationHandling.presentation(showInForeground: true)

        XCTAssertTrue(options.contains(.sound))
        XCTAssertTrue(options.contains(.badge))
        XCTAssertFalse(options.isEmpty)
    }

    func testShowsNothingInTheForegroundWhenTheAppSwitchedItOff() {
        XCTAssertTrue(NotificationHandling.presentation(showInForeground: false).isEmpty)
    }

    func testATapOnTheNotificationOpensItsLink() {
        let url = NotificationHandling.linkToOpen(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: ["action_url": "https://app.example.test/orders/1"],
            push: push()
        )

        XCTAssertEqual(url?.absoluteString, "https://app.example.test/orders/1")
    }

    func testADismissOrACustomActionOpensNothing() {
        let userInfo: [AnyHashable: Any] = ["action_url": "https://app.example.test/orders/1"]

        XCTAssertNil(NotificationHandling.linkToOpen(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: userInfo, push: push()))
        XCTAssertNil(NotificationHandling.linkToOpen(actionIdentifier: "custom.action", userInfo: userInfo, push: push()))
    }

    func testALinkInASchemeTheAppDidNotAllowOpensNothing() {
        XCTAssertNil(NotificationHandling.linkToOpen(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: ["action_url": "myapp://orders/1"],
            push: push()
        ))
        XCTAssertNotNil(NotificationHandling.linkToOpen(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: ["action_url": "myapp://orders/1"],
            push: push(schemes: ["myapp"])
        ))
    }
}
#endif
