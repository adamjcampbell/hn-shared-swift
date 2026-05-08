/// One-shot completion callback fired when an awaitable dispatch
/// finishes on the Swift side. Symmetric with the existing Sink
/// protocols (SnapshotSink, CommandSink, SearchQuerySink); jextract
/// turns it into a Java interface (`com.example.appcore.bridge.DispatchCompletion`)
/// thanks to `enableJavaCallbacks: true` in `swift-java.config`. The
/// Kotlin side wraps each call in `suspendCancellableCoroutine`,
/// passing a single-shot completion that resumes the continuation when
/// `complete()` fires.
///
/// Method name `complete()` rather than `deliver` so the JVM signature
/// `()V` doesn't collide with `SnapshotSink.deliver(snapshotJSON:)` if
/// a single Kotlin object ever implements both.
public protocol DispatchCompletion: Sendable {
    func complete()
}
