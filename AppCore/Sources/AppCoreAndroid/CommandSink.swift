/// Sink for one-shot command deliveries from Swift to Kotlin — the
/// counterpart to the per-property observation reads. Each `AppCommand`
/// case has its own typed method; the Swift side does the case dispatch
/// in `AndroidCommands` and never serialises a wire payload.
///
/// jextract turns this protocol into a Java interface
/// (`com.example.appcore.bridge.CommandSink`) thanks to
/// `enableJavaCallbacks: true` in `swift-java.config`. The Kotlin side
/// implements the interface and registers an instance with
/// `appcoreCreate`.
///
/// Adding a new `AppCommand` case means adding a new method here, a new
/// `case` arm in `AndroidCommands.start()`, and a Kotlin override on
/// `AppModelHolder`.
public protocol CommandSink: Sendable {
    func presentURL(value: String)
}
