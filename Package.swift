// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermesiPush",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(name: "HermesiPush", targets: ["HermesiPush"]),
    ],
    targets: [
        .target(name: "HermesiPush"),
        .testTarget(name: "HermesiPushTests", dependencies: ["HermesiPush"]),
    ],
    swiftLanguageVersions: [.v5]
)
