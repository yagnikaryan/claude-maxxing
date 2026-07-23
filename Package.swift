// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeMaxx",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeMaxx",
            path: "Sources/ClaudeMaxx"
        ),
        .testTarget(
            name: "ClaudeMaxxTests",
            dependencies: ["ClaudeMaxx"],
            path: "Tests/ClaudeMaxxTests"
        )
    ]
)
