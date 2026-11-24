// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "command98",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "command98", targets: ["command98CLI"]),
    ],
    targets: [
        .target(name: "CSupport", path: "Sources/CSupport"),
        // the interpreter itself, as a library so the test target can link it
        .target(
            name: "command98",
            dependencies: ["CSupport"],
            path: "Sources/command98",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("Shell32", .when(platforms: [.windows]))]
        ),
        .executableTarget(
            name: "command98CLI",
            dependencies: ["command98"],
            path: "Sources/command98CLI",
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
