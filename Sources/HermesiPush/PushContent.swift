import Foundation

/// What a Hermesi push notification says, read out of the payload APNs delivered.
///
/// Hermesi puts the title and body in the standard `aps.alert`, and everything else at the top level of the payload.
/// The link a tap should open travels there under ``actionURLKey``.
public struct PushContent: Sendable, Equatable {
    public let title: String?
    public let body: String?
    /// Every string entry the template set, plus ``actionURLKey`` when there is a link.
    public let data: [String: String]

    /// The payload key Hermesi puts the link under.
    public static let actionURLKey = "action_url"

    public init(title: String?, body: String?, data: [String: String]) {
        self.title = title
        self.body = body
        self.data = data
    }

    /// Reads a notification's `userInfo`: the payload as APNs delivered it.
    public init(userInfo: [AnyHashable: Any]) {
        let alert = (userInfo["aps"] as? [String: Any])?["alert"]
        if let alert = alert as? [String: Any] {
            title = alert["title"] as? String
            body = alert["body"] as? String
        } else {
            title = nil
            body = alert as? String
        }
        var strings: [String: String] = [:]
        for (key, value) in userInfo {
            if let key = key as? String, key != "aps", let value = value as? String { strings[key] = value }
        }
        data = strings
    }

    private static let alwaysAllowedSchemes: Set<String> = ["https", "http"]

    /// The link to open on a tap, or nil. A link comes from a template, not from the app, so only the schemes the app
    /// listed are opened: `http` and `https` always, and the app's own deep link schemes through
    /// ``HermesiPushOptions/deepLinkSchemes``. Anything else (`file`, `javascript`, `tel`, `data`) is dropped.
    public func actionURL(deepLinkSchemes: Set<String> = []) -> URL? {
        guard let raw = data[Self.actionURLKey]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        // Platforms differ on what `URL(string:)` forgives (newer ones percent-encode a space), so a string that is not
        // already a URL is refused here instead of being repaired into one nobody wrote.
        guard !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased()
        else { return nil }
        let allowed = Self.alwaysAllowedSchemes.union(deepLinkSchemes.map { $0.lowercased() })
        return allowed.contains(scheme) ? url : nil
    }
}
