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
/// **Thread contract.** Swift fires `onChange()` synchronously inside
/// the property's `willSet`, on whichever thread did the write — for
/// the bridge that is always Android's main `Looper` (writes go through
/// `JavaUIActor`-isolated dispatch arms). Kotlin's implementation must
/// not re-enter Swift to re-read the property synchronously: the read
/// during willSet would see pre-mutation backing storage. Instead defer
/// the re-registration through `Handler.post(...)` (see
/// `ObservationHandle` in `SwiftObservable.kt`), which runs the
/// re-registration on the next main-looper iteration after the writer's
/// setter unwinds.
///
/// **One-shot.** `withObservationTracking`'s `onChange` fires at most
/// once per registration. Re-registration is the composable's
/// responsibility via the `remember(counter.intValue)` → `appcoreObserve`
/// cycle driven by recomposition.
public protocol ObservationCallback: Sendable {
    func onChange()
}
