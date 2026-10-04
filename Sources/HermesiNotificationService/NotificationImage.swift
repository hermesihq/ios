import Foundation

/// Where a push payload says its picture is.
///
/// APNs has no image field. A picture reaches the screen only through a notification service extension, which reads a URL
/// out of the payload and downloads it. Hermesi puts it under `image_url` when it sends through APNs directly, and Firebase
/// puts it under `fcm_options.image` when it sends through Firebase; this reads either.
public enum NotificationImage {
    /// The URL of the picture the payload asks for, or nil. Only `https` is accepted: the extension fetches this on the
    /// device, the URL comes from a template and not from the app, and iOS refuses plain `http` anyway.
    public static func url(in userInfo: [AnyHashable: Any]) -> URL? {
        let fromHermesi = userInfo["image_url"] as? String
        let fromFirebase = (userInfo["fcm_options"] as? [String: Any])?["image"] as? String
        for candidate in [fromHermesi, fromFirebase] {
            if let url = secureURL(candidate) { return url }
        }
        return nil
    }

    static func secureURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        // Platforms differ on what `URL(string:)` forgives (newer ones percent-encode a space), so a string that is not
        // already a URL is refused here instead of being repaired into one nobody wrote.
        guard !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
