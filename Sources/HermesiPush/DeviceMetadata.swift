import Foundation

/// The metadata stored with a device in Hermesi.
///
/// `transport` is how Hermesi decides which provider carries a device, so it comes from the kind of token (`apns` or `fcm`) and is set
/// after anything the app adds: an app that overrode it would send its devices to a provider that cannot reach them.
/// The same goes for `platform`.
enum DeviceMetadata {
    static let sdkVersion = "0.2.0"

    static func build(transport: String, osVersion: String, appVersion: String?, extra: [String: Any]) -> [String: Any] {
        var metadata: [String: Any] = [
            "os_version": osVersion,
            "sdk": "hermesi-ios/\(sdkVersion)",
        ]
        if let appVersion { metadata["app_version"] = appVersion }
        for (key, value) in extra { metadata[key] = value }
        metadata["platform"] = "ios"
        metadata["transport"] = transport
        return metadata
    }
}
