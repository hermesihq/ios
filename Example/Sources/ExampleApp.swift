import SwiftUI
import UIKit

@main
struct ExampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { ContentView(model: Model.shared) }
    }
}

/// iOS hands the push token to the app delegate, so this is where an app passes it to the SDK.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { @MainActor in Model.shared.configure() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in Model.shared.didReceive(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            Model.shared.log("iOS could not get a push token: \(error.localizedDescription). The simulator needs a Mac with Apple silicon or a T2 chip; otherwise use a device.")
        }
    }
}
