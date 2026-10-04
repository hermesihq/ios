#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// A notification service extension that attaches the picture a Hermesi notification asks for.
///
/// iOS lets an app change a notification before it is shown only through a *notification service extension*, a separate
/// target of your app. Add one (File > New > Target > Notification Service Extension), make this package's
/// `HermesiNotificationService` product a dependency of that target (and of that target only), and replace its template
/// class with:
///
/// ```swift
/// import HermesiNotificationService
///
/// final class NotificationService: HermesiNotificationServiceExtension {}
/// ```
///
/// It reads the picture's URL from the payload (see ``NotificationImage``), downloads it, and attaches it. If anything goes
/// wrong, or iOS runs out of the extension's time, the notification is delivered as it was, without the picture.
///
/// Hermesi sets `mutable-content` on a notification that has a picture, which is what makes iOS run the extension. Override
/// ``prepare(_:)`` to change anything else about the content first.
open class HermesiNotificationServiceExtension: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNNotificationContent?
    private var task: Task<Void, Never>?

    /// Called with the content before the picture is added. The default does nothing.
    open func prepare(_ content: UNMutableNotificationContent) {}

    public override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return contentHandler(request.content)
        }
        prepare(mutable)
        lock.lock()
        self.contentHandler = contentHandler
        bestAttempt = mutable
        lock.unlock()

        guard let url = NotificationImage.url(in: request.content.userInfo) else { return deliver() }
        let task = Task { [weak self] in
            if let image = await ImageDownloader().download(url),
               let attachment = Self.attachment(for: image) {
                mutable.attachments = [attachment]
            }
            self?.deliver()
        }
        lock.lock()
        self.task = task
        lock.unlock()
    }

    /// iOS is about to kill the extension. Deliver what there is.
    public override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        deliver()
    }

    /// The content goes out exactly once, whichever of the download and the deadline gets here first.
    private func deliver() {
        lock.lock()
        let handler = contentHandler
        let content = bestAttempt
        contentHandler = nil
        lock.unlock()
        if let handler, let content { handler(content) }
    }

    /// The attachment for a picture. iOS decides how to draw it from the file's extension, so it is written to a file with
    /// the right one. The system moves the file out of the extension's temporary directory.
    static func attachment(for image: DownloadedImage) -> UNNotificationAttachment? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("image").appendingPathExtension(image.fileExtension)
            try image.data.write(to: file)
            return try UNNotificationAttachment(identifier: "hermesi-image", url: file, options: nil)
        } catch {
            return nil
        }
    }
}
#endif
