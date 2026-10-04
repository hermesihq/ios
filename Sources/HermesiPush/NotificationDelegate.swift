#if canImport(UIKit) && canImport(UserNotifications)
import UIKit
import UserNotifications

/// Shows Hermesi's notifications while the app is open, and opens a tapped notification's link.
///
/// iOS draws a notification itself when the app is in the background and draws nothing when it is open, unless the
/// app's `UNUserNotificationCenterDelegate` asks it to. Set this as that delegate:
///
/// ```swift
/// let delegate = HermesiNotificationDelegate(push: push)   // keep a strong reference: the center holds it weakly
/// UNUserNotificationCenter.current().delegate = delegate
/// ```
///
/// A tap opens the notification's link if it is one the app allows (``HermesiPushOptions/deepLinkSchemes``). If your
/// app already has a delegate, call ``HermesiPush/actionURL(userInfo:)`` from it instead.
public final class HermesiNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let push: HermesiPush
    private let openURL: (URL) -> Void

    /// - Parameter openURL: What to do with a link. The default opens it with `UIApplication`.
    public init(push: HermesiPush, openURL: @escaping (URL) -> Void = { url in UIApplication.shared.open(url) }) {
        self.push = push
        self.openURL = openURL
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(NotificationHandling.presentation(showInForeground: push.options.showInForeground))
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let url = NotificationHandling.linkToOpen(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo,
            push: push
        ) {
            DispatchQueue.main.async { self.openURL(url) }
        }
        completionHandler()
    }
}

extension HermesiPush {
    /// Asks the person for permission to show notifications and, if they agree, asks iOS for a push token, which arrives
    /// in `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`. Call it at a moment of your choosing, not
    /// at launch. Returns whether permission was granted.
    @MainActor
    public static func requestAuthorization(
        options: UNAuthorizationOptions = [.alert, .badge, .sound]
    ) async throws -> Bool {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }
}
#endif
