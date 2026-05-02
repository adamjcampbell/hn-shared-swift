// swift-tools-version: 6.0
import PackageDescription

let sharedSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableExperimentalFeature("StrictConcurrency"),
]

let package = Package(
    name: "AppCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "AppCoreAndroid", targets: ["AppCoreAndroid"]),
    ],
    targets: [
        .target(
            name: "AppCore",
            swiftSettings: sharedSettings
        ),
        .target(
            name: "AppCoreAndroid",
            dependencies: ["AppCore"],
            swiftSettings: sharedSettings
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore"],
            swiftSettings: sharedSettings
        ),
    ]
)
