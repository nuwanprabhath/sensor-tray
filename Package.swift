// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sensor-tray",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (protocol decoding, storage, CSV): no CoreBluetooth, no UI.
        .target(
            name: "SensorTrayCore",
            path: "Sources/SensorTrayCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "SensorTray",
            dependencies: ["SensorTrayCore"],
            path: "Sources/SensorTray",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Assertion runner standing in for XCTest, which needs a full Xcode
        // install. Run with `swift run SensorTrayChecks`.
        .executableTarget(
            name: "SensorTrayChecks",
            dependencies: ["SensorTrayCore"],
            path: "Sources/SensorTrayChecks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
