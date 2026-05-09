/// One-shot notification fired when any `@Observable` property
/// accessed during a prior `appcoreObserve` scope changes.
///
/// Kotlin implements this to increment a `MutableIntState` counter that
/// triggers Compose recomposition. The composable's
/// `remember(counter.intValue)` block re-runs on recomposition,
/// calling `appcoreObserve` again to register the next scope — exactly
/// mirroring how SwiftUI re-evaluates `body` to re-arm its own
/// `withObservationTracking` tracking.
///
/// jextract generates a Java interface
/// `com.example.appcore.bridge.ObservationCallback` from this protocol.
///
/// **Thread contract.** Swift fires `onChange()` via
/// `Task { @JavaUIActor in … }` — it always arrives on Android's main
/// Looper thread. Kotlin's implementation can safely read and write
/// Compose `MutableState` directly.
///
/// **One-shot.** `withObservationTracking`'s `onChange` fires at most
/// once per registration. Re-registration is the composable's
/// responsibility via the `remember(counter.intValue)` → `appcoreObserve`
/// cycle driven by recomposition.
public protocol ObservationCallback: Sendable {
    func onChange()
}
