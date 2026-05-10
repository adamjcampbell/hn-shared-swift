/// JNI mirror of the closure that fires when an `@Observable` property
/// observed by `appcoreObserveGet*` mutates.
///
/// jextract generates a Java interface `com.example.appcore.bridge.OnChange`
/// from this protocol. Kotlin uses it as a SAM-convertible interface:
/// `OnChange { … }` is a one-shot callback whose body runs on the bridge's
/// main-looper thread.
///
/// **Thread contract.** Swift fires `onChange()` from a `@JavaUIActor`-
/// isolated Task that's iterating an `Observations` AsyncSequence. The
/// Task's executor is `LooperExecutor`, pinned to Android's main
/// `Looper`, so `onChange()` always arrives on the UI thread. Kotlin's
/// implementation can read and write Compose `MutableState` directly.
///
/// **Synchronous re-arm is safe.** Unlike `withObservationTracking`'s
/// `onChange` (which fires *inside* the property's willSet, before the
/// mutation has committed), `Observations` emits at transaction end —
/// after didSet. The new value is fully committed by the time
/// `onChange()` fires, so Kotlin's `OnChange` can synchronously call
/// `appcoreObserveGet*` again to re-arm and read the post-mutation
/// value. No `Handler.post` deferral is needed.
///
/// **Lifecycle.** Each `appcoreObserve*` call spawns a long-lived
/// `Observations { … }.dropFirst()` Task and returns a cancellation
/// token. The Task fires `onChange()` on every emission until cancelled.
/// `SwiftBinding.dispose()` calls `appcoreCancelObservation(token)` to
/// tear the chain down immediately on Compose disposal — the for-await
/// loop exits, the JNI global ref drops, and GC reclaims the callback
/// without waiting for a future Swift mutation. `Bridge.detach` (called
/// by `appcoreDestroy`) also cancels any tokens still outstanding, so
/// tests that destroy without explicit cancel don't leak Tasks.
public protocol OnChange: Sendable {
    func onChange()
}
