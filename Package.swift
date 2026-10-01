// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacLinker",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CVirtualDisplay", path: "Sources/CVirtualDisplay", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(name: "MacLinker", dependencies: ["CVirtualDisplay"], path: "Sources/MacLinker"),
        .testTarget(name: "MacLinkerTests", dependencies: ["MacLinker"], path: "Tests/MacLinkerTests"),
    ]
)
