// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MessagesStorageSaver",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StorageSaverCore", targets: ["StorageSaverCore"]),
        .executable(name: "mss", targets: ["mss"]),
        .executable(name: "MessagesStorageSaver", targets: ["MessagesStorageSaver"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Read-only analysis, the offload engine, journal, canaries, health, restore.
        .target(
            name: "StorageSaverCore",
            path: "Sources/StorageSaverCore"
        ),
        // Apple's dormant cache-delete switches and daemon restart. Research
        // only: linked by the CLI, never by the app.
        .target(
            name: "StorageSaverExperimental",
            dependencies: ["StorageSaverCore"],
            path: "Sources/StorageSaverExperimental"
        ),
        .executableTarget(
            name: "mss",
            dependencies: [
                "StorageSaverCore",
                "StorageSaverExperimental",
                "StorageSaverAutomation",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/mss"
        ),
        // Presses Messages' own "Sync Now" button through Accessibility (the
        // daemon accepts sync requests only from Messages itself). AppKit only.
        .target(
            name: "StorageSaverAutomation",
            path: "Sources/StorageSaverAutomation"
        ),
        // Menu-bar app logic and views, as a library so it can be tested.
        .target(
            name: "StorageSaverAppKit",
            dependencies: ["StorageSaverCore", "StorageSaverAutomation"],
            path: "Sources/StorageSaverAppKit"
        ),
        .executableTarget(
            name: "MessagesStorageSaver",
            dependencies: ["StorageSaverAppKit"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "StorageSaverCoreTests",
            dependencies: ["StorageSaverCore"],
            path: "Tests/StorageSaverCoreTests"
        ),
        .testTarget(
            name: "StorageSaverAppKitTests",
            dependencies: ["StorageSaverAppKit", "StorageSaverCore"],
            path: "Tests/StorageSaverAppKitTests"
        ),
    ]
)
