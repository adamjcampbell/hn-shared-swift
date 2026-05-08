import SwiftJava

/// `JavaSnapshotSink`, `JavaCommandSink`, `JavaSearchQuerySink`,
/// `JavaIsLoadingSink`, and `JavaAndroidCompletion` are jextract-generated
/// Swift wrappers for the Kotlin-implemented `SnapshotSink` /
/// `CommandSink` / `SearchQuerySink` / `IsLoadingSink` /
/// `AndroidCompletion` interfaces. They are thin handles to a JNI
/// `jobject` and are safe to share across isolation domains:
/// jextract's generated thunks attach/detach the JVM thread per call.
///
/// The swift-java tool does not yet mark `@JavaInterface`-generated
/// wrappers as `Sendable`, so we adopt it here. These are the only
/// `@unchecked Sendable` declarations in `AppCore/Sources/`, and they
/// exist purely to bridge a tooling gap — the corresponding protocol
/// `Sendable` requirements (declared alongside each protocol) would
/// otherwise fail to compile because the wrapper structs don't
/// synthesise the conformance themselves.
extension JavaSnapshotSink: @unchecked Sendable {}
extension JavaCommandSink: @unchecked Sendable {}
extension JavaSearchQuerySink: @unchecked Sendable {}
extension JavaIsLoadingSink: @unchecked Sendable {}
extension JavaAndroidCompletion: @unchecked Sendable {}
