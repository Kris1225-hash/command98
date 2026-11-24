// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "command98",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "command98",
            path: "Sources/command98",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "command98Tests",
            dependencies: ["command98"],
            path: "Tests/command98Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
