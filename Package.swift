// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacLinker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MacLinker", path: "Sources/MacLinker"),
        .testTarget(name: "MacLinkerTests", dependencies: ["MacLinker"], path: "Tests/MacLinkerTests"),
    ]
)
