/// JNI mirror of the closure that fires when an `@Observable` property
/// observed by `appcoreObserve*` mutates. Each protocol below is the
/// per-Swift-type variant of "OnChange" — jextract doesn't bridge
/// generic protocols, so each observed value type needs its own
/// SAM-friendly interface.
///
/// Adding a new observed type means:
/// 1. A new protocol below (single method, single value parameter).
/// 2. A new `Java<TypeName>: @unchecked Sendable {}` line in
///    `JavaInterop.swift`.
///
/// **Why value-carrying?** The callback delivers the new value
/// directly, so Kotlin's handler can write it to Compose state without
/// a separate Kotlin→Swift `appcoreReadX` round-trip. Per emission:
/// 1 S→K callback instead of 1 callback + 1 read thunk.
///
/// **Thread contract.** Swift fires `onChange(value:)` from a
/// `@JavaUIActor`-isolated Task that's iterating an `Observations`
/// AsyncSequence. The Task's executor is `LooperExecutor`, pinned to
/// Android's main `Looper`, so `onChange(value:)` always arrives on the
/// UI thread. Kotlin's implementation can read and write Compose
/// `MutableState` directly.
///
/// **Synchronous handler is safe.** `Observations` (SE-0475) emits at
/// transaction end (after didSet), not inside willSet. The new value
/// passed to `onChange(value:)` is fully committed by the time it
/// fires — no willSet race to work around.
///
/// **Lifecycle.** Each `appcoreObserve*` call spawns a long-lived
/// `Observations { … }.dropFirst()` Task and returns
/// `(token, initialValue)`. The Task fires `onChange(value:)` on every
/// emission until cancelled. `SwiftBinding.dispose()` calls
/// `appcoreCancelObservation(token)` to tear the chain down
/// immediately; `Bridge.detach` (called by `appcoreDestroy`) sweeps
/// any tokens still outstanding.

public protocol BoolOnChange: Sendable {
    func onChange(value: Bool)
}

public protocol StringOnChange: Sendable {
    func onChange(value: String)
}

public protocol OptionalStringOnChange: Sendable {
    func onChange(value: String?)
}

public protocol LongOnChange: Sendable {
    func onChange(value: Int64)
}
