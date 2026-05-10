import SwiftJava

/// `JavaCommandSink`, `JavaAndroidCompletion`, and the typed
/// `Java<Type>OnChange` wrappers are jextract-generated Swift wrappers
/// for the Kotlin-implemented `CommandSink` / `AndroidCompletion` /
/// `*OnChange` interfaces.
/// They are thin handles to a JNI `jobject` and are safe to share across
/// isolation domains: jextract's generated thunks attach/detach the JVM
/// thread per call.
///
/// The swift-java tool does not yet mark `@JavaInterface`-generated
/// wrappers as `Sendable`, so we adopt it here. These are the only
/// `@unchecked Sendable` declarations in `AppCore/Sources/`, and they
/// exist purely to bridge a tooling gap — the corresponding protocol
/// `Sendable` requirements (declared alongside each protocol) would
/// otherwise fail to compile because the wrapper structs don't
/// synthesise the conformance themselves.
extension JavaCommandSink: @unchecked Sendable {}
extension JavaAndroidCompletion: @unchecked Sendable {}
extension JavaBoolOnChange: @unchecked Sendable {}
extension JavaStringOnChange: @unchecked Sendable {}
extension JavaOptionalStringOnChange: @unchecked Sendable {}
extension JavaLongOnChange: @unchecked Sendable {}
