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
        .package(url: "https://github.com/swiftlang/swift-java", revision: "301e3da710ede7af93e798f1ce1c7950715a5748"),
        // Test-only: deterministic time control via TestClock so the
        // 250 ms search debounce doesn't translate into 250 ms of
        // real-clock waiting per test.
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "PlatformSupport",
            dependencies: [.product(name: "SwiftJava", package: "swift-java", condition: .when(platforms: [.android]))],
            swiftSettings: sharedSettings
        ),
        .target(
            name: "HackerNews",
            dependencies: ["PlatformSupport"],
            swiftSettings: sharedSettings
        ),
        .target(
            name: "HackerNewsReader",
            dependencies: [
                "HackerNews",
                "PlatformSupport",
            ],
            resources: [.process("Resources")],
            swiftSettings: sharedSettings
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
