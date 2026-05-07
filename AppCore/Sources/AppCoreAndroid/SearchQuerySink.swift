/// Sink for `searchQuery` deliveries from Swift to Kotlin.
///
/// jextract turns this protocol into a Java interface
/// (`com.example.appcore.bridge.SearchQuerySink`) thanks to
/// `enableJavaCallbacks: true` in `swift-java.config`. The Kotlin side
/// implements the interface and registers an instance with `appcoreCreate`.
///
/// `searchQuery` is the one piece of state that doesn't ride the JSON
/// snapshot: both platforms two-way-bind it to a UI control (iOS via
/// `@Bindable` + `$state.searchQuery`, Android via `BridgedSource` +
/// `appcoreSetSearchQuery`), so a per-property sink is the simpler shape
/// than encoding it inside a snapshot blob. The bridge dedups echoes of
/// Compose-originated writes via `lastSetterValue`, so this sink fires
/// only for cold-start initial values and genuine programmatic Swift
/// writes (a future "clear search" button, etc.).
public protocol SearchQuerySink: Sendable {
    func deliverSearchQuery(value: String)
}
