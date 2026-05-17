// swift-tools-version: 6.1
import PackageDescription

let sharedSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableExperimentalFeature("StrictConcurrency"),
]

let package = Package(
    name: "HackerNewsReader",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        // 15.4 floor lets `TestCore` use SE-0371 `isolated deinit` to
        // break the listener-task retain cycle on test-scope exit.
        // The iOS minimum stays at 17 because production deinit is
        // never reached — the module-level `appCore` is app-lifetime.
        .macOS("15.4"),
    ],
    products: [
        .library(name: "HackerNewsReader", type: .dynamic, targets: ["HackerNewsReader"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.8.14"),
        .package(url: "https://source.skip.tools/skip-fuse.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-model.git", from: "1.0.0"),
        // Test-only: deterministic time control via TestClock so the
        // 250 ms search debounce doesn't translate into 250 ms of
        // real-clock waiting per test.
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "HackerNews",
            dependencies: [
                .product(name: "SkipFuse", package: "skip-fuse"),
            ],
            swiftSettings: sharedSettings,
            plugins: [.plugin(name: "skipstone", package: "skip")]
        ),
        .target(
            name: "HackerNewsReader",
            dependencies: [
                "HackerNews",
                .product(name: "SkipFuse", package: "skip-fuse"),
                .product(name: "SkipModel", package: "skip-model"),
            ],
            resources: [.process("Resources")],
            swiftSettings: sharedSettings,
            plugins: [.plugin(name: "skipstone", package: "skip")]
        ),
        .testTarget(
            name: "HackerNewsTests",
            dependencies: [
                "HackerNews",
            ],
            swiftSettings: sharedSettings
        ),
        .testTarget(
            name: "HackerNewsReaderTests",
            dependencies: [
                "HackerNewsReader",
                .product(name: "Clocks", package: "swift-clocks"),
            ],
            swiftSettings: sharedSettings
        ),
    ]
)
