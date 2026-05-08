/// Generic one-shot completion callback for Swift → Kotlin awaitable
/// JNI calls. The standardised shape behind every `appcore…Await(…)`
/// thunk: Swift kicks off async work, then fires `complete()` when the
/// work resolves; the Kotlin caller's `suspendCancellableCoroutine`
/// resumes its continuation at that point.
///
/// jextract turns this protocol into a Java interface
/// (`com.example.appcore.bridge.AndroidCompletion`) thanks to
/// `enableJavaCallbacks: true` in `swift-java.config`. The Kotlin
/// side has a small `awaitWithCompletion { thunk -> … }` helper that
/// wraps any thunk taking an `AndroidCompletion` into a `suspend fun`.
///
/// Method name `complete()` rather than `deliver` so the JVM signature
/// `()V` doesn't collide with `SnapshotSink.deliver(snapshotJSON:)` if
/// a single Kotlin object ever implements both.
///
/// **Future result-bearing variant.** A `AndroidResultCompletion<T>`
/// could specialise per concrete `T` (jextract limitation: no generic
/// protocols), e.g. `AndroidStringResultCompletion: Sendable {
/// func complete(result: String) }`. Defer until needed.
public protocol AndroidCompletion: Sendable {
    func complete()
}
