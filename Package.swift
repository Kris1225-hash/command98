// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "command98",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CSupport", path: "Sources/CSupport"),
        .executableTarget(
            name: "command98",
            dependencies: ["CSupport"],
            path: "Sources/command98",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
