// swift-tools-version: 5.9
// RoostKit: platform-independent logic shared by the iOS app. Builds and tests
// on Linux and Apple platforms: `swift test` from this directory.
import PackageDescription

let package = Package(
    name: "RoostKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "RoostKit", targets: ["RoostKit"])],
    targets: [
        .target(name: "RoostKit", resources: [.copy("Resources/taxonomy.json")]),
        .testTarget(name: "RoostKitTests", dependencies: ["RoostKit"]),
    ]
)
