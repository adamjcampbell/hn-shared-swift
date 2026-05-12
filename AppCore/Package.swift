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
        // `merge` (and friends) for the AppEventHandler run() pipeline.
        // Used only inside the non-bridged handler — Skip's native mode
        // compiles it as plain Swift for both targets.
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        // Test-only: deterministic time control via TestClock so the
        // 250 ms debounce in AppModel doesn't translate into 250 ms of
        // real-clock waiting per test.
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "AppCore",
            dependencies: [
                .product(name: "SkipFuse", package: "skip-fuse"),
                .product(name: "SkipModel", package: "skip-model"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
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
