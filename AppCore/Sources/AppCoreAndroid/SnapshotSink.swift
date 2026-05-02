/// Sink for snapshot deliveries from Swift to Kotlin.
///
/// jextract turns this protocol into a Java interface
/// (`com.example.appcore.bridge.SnapshotSink`) thanks to
/// `enableJavaCallbacks: true` in `swift-java.config`. The Kotlin side
/// implements the interface and registers an instance with `appcoreCreate`.
public protocol SnapshotSink {
    func deliver(snapshotJSON: String)
}
