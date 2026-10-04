import Foundation
import HermesiPush
import UserNotifications

/// What the person types into the sample, kept between launches.
struct Settings {
    private let defaults = UserDefaults.standard

    // The iOS simulator shares your Mac's network, so localhost works. A phone needs your Mac's address.
    var apiBaseURL: String {
        get { defaults.string(forKey: "apiBaseURL") ?? "http://localhost:8010/v1/client" }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "apiBaseURL") }
    }
    var publicKey: String {
        get { defaults.string(forKey: "publicKey") ?? "" }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "publicKey") }
    }
    var tokenServerURL: String {
        get { defaults.string(forKey: "tokenServerURL") ?? "http://localhost:8787" }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "tokenServerURL") }
    }
    var subscriber: String {
        get { defaults.string(forKey: "subscriber") ?? "user_1" }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "subscriber") }
    }
}

@MainActor
final class Model: ObservableObject {
    static let shared = Model()

    @Published private(set) var lines: [String] = []

    private var push: HermesiPush?
    private var deviceToken: Data?
    // The notification center holds its delegate weakly, so the app has to keep it.
    private var notificationDelegate: HermesiNotificationDelegate?

    /// Builds the SDK from the saved settings. An app of your own does this once, at launch; the sample does it again
    /// when the settings change.
    func configure() {
        let settings = Settings()
        let tokenServer = settings.tokenServerURL
        let subscriber = settings.subscriber
        let client = HermesiClient(options: HermesiClientOptions(
            publicKey: settings.publicKey,
            apiBaseURL: settings.apiBaseURL,
            // In a real app this asks YOUR backend for a token for the signed-in person. Here it asks the development
            // token server in Example/token-server, which will mint one for anybody.
            subscriberToken: { try await Model.fetchSubscriberToken(server: tokenServer, subscriber: subscriber) }
        ))
        // The sample's own deep link: a notification whose link is sample://orders/4821 is allowed through.
        let push = HermesiPush(client: client, options: HermesiPushOptions(deepLinkSchemes: ["sample"]))
        self.push = push
        let delegate = HermesiNotificationDelegate(push: push) { [weak self] url in
            // An app of your own would navigate. The sample just says what it was asked to open.
            Task { @MainActor in self?.log("A tap opened the link: \(url)") }
        }
        notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    func save(apiBaseURL: String, publicKey: String, tokenServerURL: String, subscriber: String) {
        let settings = Settings()
        settings.apiBaseURL = apiBaseURL
        settings.publicKey = publicKey
        settings.tokenServerURL = tokenServerURL
        settings.subscriber = subscriber
        configure()
        log("Settings saved.")
    }

    func requestPermission() {
        Task {
            do {
                let granted = try await HermesiPush.requestAuthorization()
                log(granted ? "Notifications allowed. iOS is getting a push token." : "Notifications were not allowed. Change it in Settings > Notifications.")
            } catch {
                log("Could not ask: \(error.localizedDescription)")
            }
        }
    }

    /// iOS delivers the token here, at every launch once permission is given. `tokenDidChange` registers it if this device
    /// was registered before (it is ignored before the person has signed in), so a rotated token is never lost.
    func didReceive(deviceToken: Data) {
        self.deviceToken = deviceToken
        log("iOS gave a push token (\(deviceToken.count) bytes).")
        guard let push else { return }
        Task {
            do {
                if try await push.tokenDidChange(.apns(deviceToken)) { log("The token had changed: registered the new one.") }
            } catch {
                report(error)
            }
        }
    }

    func register() {
        guard let push else { return log("Not configured.") }
        guard let deviceToken else { return log("No push token yet. Tap Allow notifications first.") }
        Task {
            do {
                // `plan` is metadata of your own, stored with the device. platform and transport are set by the SDK.
                try await push.register(.apns(deviceToken), metadata: ["plan": "sample"])
                log("Registered. Hermesi now has this device, with transport apns.")
            } catch {
                report(error)
            }
        }
    }

    func unregister() {
        guard let push else { return log("Not configured.") }
        Task {
            do {
                try await push.unregister()
                log("Unregistered.")
            } catch {
                report(error)
            }
        }
    }

    func log(_ line: String) {
        lines.append(line)
    }

    private func report(_ error: Error) {
        if let error = error as? HermesiAPIError {
            log("Hermesi refused: \(error.code) (HTTP \(error.status)): \(error.message)")
        } else {
            log("Failed: \(error.localizedDescription). A URL above may be wrong, or something is not running.")
        }
    }

    nonisolated private static func fetchSubscriberToken(server: String, subscriber: String) async throws -> String {
        var components = URLComponents(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/token")
        components?.queryItems = [URLQueryItem(name: "subscriber", value: subscriber)]
        guard let url = components?.url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let token = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? String
        else { throw URLError(.badServerResponse) }
        return token
    }
}
