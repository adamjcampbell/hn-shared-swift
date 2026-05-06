/// Sink for one-shot command deliveries from Swift to Kotlin — the
/// symmetric counterpart to `SnapshotSink`. `SnapshotSink` carries
/// `AppState` snapshots (UI ← Core, state); this protocol carries
/// `AppCommand` values (UI ← Core, imperative requests).
///
/// jextract turns this protocol into a Java interface
/// (`com.example.appcore.bridge.CommandSink`) thanks to
/// `enableJavaCallbacks: true` in `swift-java.config`. The Kotlin side
/// implements the interface and registers an instance with
/// `appcoreCreate`.
///
/// **Why `deliverCommand`, not `deliver`:** the JVM method signature is
/// (Ljava/lang/String;)V regardless of parameter name, so naming this
/// `deliver` would collide with `SnapshotSink.deliver(snapshotJSON:)`
/// when a single Kotlin object implements both interfaces (which is
/// exactly what `AppModelHolder` does).
public protocol CommandSink: Sendable {
    func deliverCommand(commandJSON: String)
}
