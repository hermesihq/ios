import HermesiNotificationService

/// The whole extension: iOS runs it for a notification marked `mutable-content`, which Hermesi sets when a notification has
/// a picture, and the base class downloads the picture and attaches it. Override `prepare(_:)` to change anything else.
final class NotificationService: HermesiNotificationServiceExtension {}
