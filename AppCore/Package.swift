// swift-tools-version: 6.1
import PackageDescription

let sharedSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableExperimentalFeature("StrictConcurrency"),
]

let package = Package(
    name: "AppCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AppCore", type: .dynamic, targets: ["AppCore"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.8.14"),
        .package(url: "https://source.skip.tools/skip-fuse.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-model.git", from: "1.0.0"),
        // Test-only: deterministic time control via TestClock so the
        // 250 ms debounce in AppCore doesn't translate into 250 ms of
        // real-clock waiting per test.
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "AppCore",
            dependencies: [
                .product(name: "SkipFuse", package: "skip-fuse"),
                .product(name: "SkipModel", package: "skip-model"),
            ],
            resources: [.process("Resources")],
            swiftSettings: sharedSettings,
            plugins: [.plugin(name: "skipstone", package: "skip")]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: [
                "AppCore",
                .product(name: "Clocks", package: "swift-clocks"),
            ],
            swiftSettings: sharedSettings
        ),
    ]
)
