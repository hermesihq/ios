// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermesiPush",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(name: "HermesiPush", targets: ["HermesiPush"]),
        // For the notification service extension, which is a separate target of the app and links only this: it has no
        // use for the app-side code, and an extension may not link code that touches `UIApplication`.
        .library(name: "HermesiNotificationService", targets: ["HermesiNotificationService"]),
    ],
    targets: [
        .target(name: "HermesiPush"),
        .target(name: "HermesiNotificationService"),
        .testTarget(name: "HermesiPushTests", dependencies: ["HermesiPush"]),
        .testTarget(name: "HermesiNotificationServiceTests", dependencies: ["HermesiNotificationService"]),
    ],
    swiftLanguageVersions: [.v5]
)
