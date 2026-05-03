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
        // Pinned to `main` rather than v1.6.0: the released tag caps
        // `swift-syntax` at `<603`, but `swift-java` requires `>=603`.
        // Main extends the upper bound to `<604`. Re-pin to a version
        // tag once MetaCodable cuts a release that includes the bump.
        .package(url: "https://github.com/SwiftyLab/MetaCodable.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "AppCore",
            dependencies: [
                .product(name: "MetaCodable", package: "MetaCodable"),
            ],
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
            dependencies: ["AppCore"],
            swiftSettings: sharedSettings
        ),
    ]
)
