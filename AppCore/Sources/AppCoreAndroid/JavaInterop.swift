import SwiftJava

/// `JavaSnapshotSink` is the jextract-generated Swift wrapper for the
/// Kotlin-implemented `SnapshotSink` interface. It is a thin handle to a
/// JNI `jobject` and is safe to share across isolation domains: jextract's
/// generated thunks attach/detach the JVM thread per call.
///
/// The swift-java tool does not yet mark `@JavaInterface`-generated
/// wrappers as `Sendable`, so we adopt it here. This is the *only*
/// `@unchecked Sendable` in `AppCore/Sources/`, and it exists purely to
/// bridge a tooling gap — `SnapshotSink: Sendable` (declared in
/// `SnapshotSink.swift`) would otherwise fail to compile because the
/// wrapper struct doesn't synthesise the conformance itself.
extension JavaSnapshotSink: @unchecked Sendable {}
