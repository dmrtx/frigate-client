// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FrigateClient",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "FrigateClient",
            path: "Sources/FrigateClient"),
        .testTarget(name: "FrigateClientTests", dependencies: ["FrigateClient"])
    ]
)
