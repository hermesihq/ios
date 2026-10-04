#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// The decisions ``HermesiNotificationDelegate`` makes, apart from the UIKit calls that act on them, so that they can
/// be tested without a device.
enum NotificationHandling {
    /// How to show a notification that arrives while the app is open: iOS shows none unless the delegate says so.
    static func presentation(showInForeground: Bool) -> UNNotificationPresentationOptions {
        guard showInForeground else { return [] }
        if #available(iOS 14.0, macOS 11.0, *) {
            return [.banner, .list, .sound, .badge]
        }
        return [.alert, .sound, .badge]
    }

    /// The link to open for a response to a notification, or nil. Only the tap on the notification itself opens it, not
    /// a custom action or a dismissal, and the link must be one the app allows.
    static func linkToOpen(actionIdentifier: String, userInfo: [AnyHashable: Any], push: HermesiPush) -> URL? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }
        return push.actionURL(userInfo: userInfo)
    }
}
#endif
