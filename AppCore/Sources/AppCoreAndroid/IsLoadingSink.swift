/// Sink for `isLoading` deliveries from Swift to Kotlin.
///
/// jextract turns this protocol into a Java interface
/// (`com.example.appcore.bridge.IsLoadingSink`) thanks to
/// `enableJavaCallbacks: true` in `swift-java.config`. The Kotlin side
/// implements the interface and registers an instance with `appcoreCreate`.
///
/// `isLoading` is bridged per-property rather than via the snapshot
/// because both UI consumers want per-fetch granularity (the
/// pull-to-refresh indicator + empty-overlay flicker guard fire on
/// search-typing debounced fetches, not just explicit `.refresh`).
/// Compose binds the value through `BridgedSource.asMutableState()`,
/// matching the `searchQuery` shape; in practice only `runFetch` writes
/// it, so the round-trip is one-way Swift → Kotlin.
public protocol IsLoadingSink: Sendable {
    func deliverIsLoading(value: Bool)
}
