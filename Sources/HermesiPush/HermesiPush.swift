import Foundation

/// How an app wants Hermesi's notifications to behave.
public struct HermesiPushOptions: Sendable {
    /// Schemes of your own deep links (for example `myapp`) that a notification's link may open. `http` and `https` are
    /// always allowed; nothing else is.
    public var deepLinkSchemes: Set<String>
    /// Whether to show a notification that arrives while the app is open. iOS shows none by itself in that case.
    public var showInForeground: Bool

    public init(deepLinkSchemes: Set<String> = [], showInForeground: Bool = true) {
        self.deepLinkSchemes = deepLinkSchemes
        self.showInForeground = showInForeground
    }
}

/// The registered token and its metadata, in `UserDefaults`.
public final class UserDefaultsTokenStore: TokenStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let tokenKey = "io.github.hermesihq.push.token"
    private let metadataKey = "io.github.hermesihq.push.metadata"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func token() -> String? { defaults.string(forKey: tokenKey) }

    public func setToken(_ token: String?) {
        if let token { defaults.set(token, forKey: tokenKey) } else { defaults.removeObject(forKey: tokenKey) }
    }

    public func metadata() -> [String: Any] {
        guard let raw = defaults.string(forKey: metadataKey),
              let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return object
    }

    public func setMetadata(_ metadata: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(raw, forKey: metadataKey)
    }
}

/// Registers this device for push notifications sent by Hermesi.
///
/// Create one and keep it for the life of the app. Call ``register(_:metadata:)`` when a subscriber signs in and
/// whenever the app receives its push token, ``tokenDidChange(_:)`` from the callback that reports a changed token, and
/// ``unregister()`` when they sign out.
///
/// The app obtains the token itself, from APNs or from Firebase, as it already does. This package takes it from there
/// and does not swizzle anything or depend on Firebase.
public final class HermesiPush: @unchecked Sendable {
    public let options: HermesiPushOptions
    private let registrar: DeviceRegistrar

    public convenience init(
        client: HermesiClient,
        options: HermesiPushOptions = HermesiPushOptions(),
        store: TokenStore = UserDefaultsTokenStore(),
        onWarning: @escaping @Sendable (String, Error) -> Void = { _, _ in }
    ) {
        self.init(api: client, options: options, store: store, onWarning: onWarning)
    }

    init(
        api: DeviceAPI,
        options: HermesiPushOptions,
        store: TokenStore,
        onWarning: @escaping @Sendable (String, Error) -> Void
    ) {
        self.options = options
        let osVersion = HermesiPush.osVersion()
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.registrar = DeviceRegistrar(
            api: api,
            store: store,
            metadata: { transport, extras in
                DeviceMetadata.build(transport: transport, osVersion: osVersion, appVersion: appVersion, extra: extras)
            },
            onWarning: onWarning
        )
    }

    /// True if ``register(_:metadata:)`` has succeeded and ``unregister()`` has not been called since.
    public var isRegistered: Bool { registrar.isRegistered }

    /// Registers this device. Call it after the subscriber has signed in, and again each time the app is handed its
    /// push token: it is safe to repeat, and it is what puts a device back after Hermesi had marked it invalid.
    /// `metadata` is stored with the device (`["plan": "pro"]`); `platform` and `transport` are always set by the SDK.
    ///
    /// Throws ``HermesiAPIError`` if Hermesi refuses and a `URLError` if it cannot be reached.
    public func register(_ token: PushToken, metadata: [String: Any] = [:]) async throws {
        try await registrar.register(token: token.identifier, transport: token.transport, metadata: metadata)
    }

    /// For the callback that reports a changed token (`didRegisterForRemoteNotificationsWithDeviceToken`, or Firebase's
    /// `didReceiveRegistrationToken`). Registers the new token and retires the old one, but only if this device had
    /// been registered: before the person signs in there is no subscriber to register it for. Returns whether it did.
    @discardableResult
    public func tokenDidChange(_ token: PushToken) async throws -> Bool {
        try await registrar.refresh(token: token.identifier, transport: token.transport)
    }

    /// Removes this device from Hermesi. Call it on sign-out. If Hermesi cannot be told, nothing changes and the
    /// failure is thrown, so the call can be repeated.
    public func unregister() async throws {
        try await registrar.unregister()
    }

    /// The link of a notification, from its `userInfo`, or nil. A link in a scheme the app did not allow is dropped.
    /// Use it from your own `UNUserNotificationCenterDelegate` if you do not use ``HermesiNotificationDelegate``.
    public func actionURL(userInfo: [AnyHashable: Any]) -> URL? {
        PushContent(userInfo: userInfo).actionURL(deepLinkSchemes: options.deepLinkSchemes)
    }

    private static func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
