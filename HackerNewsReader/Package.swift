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
        // The macOS 15.4 floor's original reason — SE-0371 `isolated
        // deinit` to break a test-scope listener-task retain cycle — is
        // obsolete; the fixture's `cancelAll()` handles that teardown now.
        // Retained as the floor (not re-derived against the Skip minimums).
        .macOS("15.4"),
    ],
    products: [
        .library(name: "HackerNewsReader", type: .dynamic, targets: ["HackerNewsReader"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.8.14"),
        .package(url: "https://source.skip.tools/skip-fuse.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-model.git", from: "1.0.0"),
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
            ],
            swiftSettings: sharedSettings
        ),
    ]
)
