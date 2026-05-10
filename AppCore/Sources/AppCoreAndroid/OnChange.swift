/// JNI mirror of the closure passed to Swift's
/// `withObservationTracking { read } onChange: { … }` — fires once when
/// any `@Observable` property accessed during a prior `appcoreObserveGet*`
/// call is mutated.
///
/// jextract generates a Java interface `com.example.appcore.bridge.OnChange`
/// from this protocol. Kotlin uses it as a SAM-convertible interface:
/// `OnChange { … }` is a one-shot callback whose body runs on the bridge's
/// main-looper thread.
///
/// **Thread contract.** Swift fires `onChange()` synchronously inside
/// the property's `willSet`, on whichever thread did the write — for
/// the bridge that is always Android's main `Looper` (writes go through
/// `JavaUIActor`-isolated dispatch arms). Kotlin's implementation must
/// not re-enter Swift to re-read the property synchronously: the read
/// during willSet would see pre-mutation backing storage. Instead defer
/// the re-registration through `Handler.post(...)` (see `SwiftBinding`
/// in `SwiftState.kt`), which runs it on the next main-looper
/// iteration after the writer's setter unwinds.
///
/// **One-shot.** `withObservationTracking`'s `onChange` fires at most
/// once per registration. Re-registration is the composable's
/// responsibility via the `SwiftBinding`-driven re-arm cycle.
public protocol OnChange: Sendable {
    func onChange()
}
