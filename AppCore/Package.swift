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
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(
            name: "AppCoreAndroid",
            type: .dynamic,
            targets: ["AppCoreAndroid"]
        ),
    ],
    dependencies: [
        .package(path: "/Users/adam/Developer/tools/swift-java"),
        // Test-only: deterministic time control via TestClock so the
        // 250 ms debounce in AppModel doesn't translate into 250 ms of
        // real-clock waiting per test.
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "AppCore",
            swiftSettings: sharedSettings
        ),
        .target(
            name: "AppCoreAndroid",
            dependencies: [
                "AppCore",
                .product(name: "SwiftJava", package: "swift-java"),
            ],
            exclude: ["swift-java.config"],
            swiftSettings: sharedSettings,
            plugins: [
                .plugin(name: "JExtractSwiftPlugin", package: "swift-java"),
            ]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: [
                "AppCore",
                .product(name: "Clocks", package: "swift-clocks"),
            ],
            swiftSettings: sharedSettings
        ),
        .testTarget(
            name: "AppCoreAndroidTests",
            dependencies: ["AppCoreAndroid"],
            swiftSettings: sharedSettings
        ),
    ]
)
