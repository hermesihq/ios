import Foundation

/// A device's push token, and which road it came from. Hermesi sends a device through the provider that speaks its
/// transport, and a token handed to the wrong one is refused as invalid, which reads as a dead device.
public enum PushToken: Sendable, Equatable {
    /// The token APNs gave the app: the `Data` from `didRegisterForRemoteNotificationsWithDeviceToken`. For an app that
    /// talks to Apple directly, with an APNs provider configured in Hermesi.
    case apns(Data)
    /// The registration token Firebase Messaging gave the app. For an app that uses Firebase, with a Firebase provider
    /// configured in Hermesi.
    case fcm(String)

    /// What Hermesi stores as the device's identifier: APNs tokens as lowercase hexadecimal, Firebase tokens as is.
    var identifier: String {
        switch self {
        case .apns(let data): return data.map { String(format: "%02x", $0) }.joined()
        case .fcm(let token): return token
        }
    }

    var transport: String {
        switch self {
        case .apns: return "apns"
        case .fcm: return "fcm"
        }
    }
}
