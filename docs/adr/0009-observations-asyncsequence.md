# ADR-0009: `Observations` AsyncSequence over `withObservationTracking`

## Status

Superseded by [ADR-0013](0013-skipfuse-bridgemembers.md) on 2026-05-10. SkipFuse intercepts Swift's `ObservationRegistrar` directly and routes its notifications into Compose's `MutableStateBacking`, so the per-binding `Observations { ... }` loops the bridge owned are no longer needed.

## Context

Once per-property bridging was in place ([ADR-0007](0007-per-property-typed-jni-thunks.md)), each bridged field needed a Swift-side observation primitive that fired when the property changed and re-armed itself for the next change. Swift's standard observation framework offered two options:

1. `withObservationTracking { read } onChange: { ... }` — the classic one-shot tracker. Reads inside the closure are registered; the `onChange` callback fires *once* when any tracked property mutates. The callback runs **inside** `willSet`, before the mutation commits.
2. `Observations { read }` (SE-0475) — an `AsyncSequence<T, Never>` that emits at *transaction end*, post-`didSet`. Re-arms internally. Cancellation is `Task` cancellation.

The first option has a well-known pitfall: re-arming inside the `onChange` body reads the property in pre-mutation state. The bridge had hit this exact symptom — a `BridgedSource<Bool>` for `isLoading` would observe a `true` value, fire onChange, re-arm by reading `isLoading`, see `false` (pre-mutation), get stuck delivering stale values to Compose. The classic workaround was to defer the re-arm with `Handler.post(...)` to the next main-looper iteration, by which time the `didSet` had completed. That worked but added a looper hop per emission and an `active: Bool` flag with a "leak until next mutation" window.

`Observations` sidesteps the race at the source. The AsyncSequence yields *after* `didSet`, so a synchronous re-read inside the consumer's loop body returns the post-mutation value directly. No deferral, no `Handler` dependency, no comment block explaining why the deferral works. The cost is being on a Swift toolchain that ships `Observations` (6.2+) and accepting that observed types must be `Sendable`. On Apple platforms this gates the runtime to iOS 26+, but the bridge only runs on Android, where the Swift runtime ships with the app (Swift Android SDK 6.3+) — so the OS-gating cost is zero.

The bridge also needed transactional batching: two synchronous mutations to `AppState` in the same method body should emit one snapshot, not two. `Observations` provides this for free (the AsyncSequence emits at transaction end; multiple pre-`didSet` mutations collapse into one yield). `withObservationTracking` requires more bookkeeping to get the same behaviour.

## Decision

The bridge uses `Observations { read }.dropFirst()` to drive every per-property observation. Each bridged field gets one long-lived `Task` that iterates the sequence and calls the value-carrying `onChange(value:)` Kotlin callback on every emission. The `Task` is registered in a `Bridge.tasks` registry; Kotlin holds the registration token and calls `appcoreCancelTask(token)` when the binding is disposed.

```swift
@JavaUIActor
private func observe<T: Sendable>(
    _ read: @escaping @Sendable (AppState) -> T,
    onChange: @escaping @Sendable (T) -> Void
) -> (Int64, T) {
    let initial = read(Bridge.appModel.state)
    let task = Task {
        for await value in Observations({ read(Bridge.appModel.state) }).dropFirst() {
            onChange(value)
        }
    }
    return (Bridge.registerTask(task), initial)
}
```

The same `Bridge.tasks` registry also tracks awaitable dispatch `Task`s (`appcoreRefreshAwait`); a cancelling Kotlin coroutine cooperatively cancels the Swift `Task` through the same `appcoreCancelTask` thunk.

## Consequences

- No `Handler.post` deferral, no `withObservationTracking` race workaround in the bridge.
- Multiple synchronous mutations in one method body coalesce into one emission, halving the JNI traffic in batch-update cases (e.g. `Engine.dispatch(.refresh)` updating `isLoading`, `stories`, and `lastRefreshedAt` in the same body).
- Cancellation is uniform: every observation Task and every awaitable dispatch Task lives in the same registry and is torn down via the same `appcoreCancelTask` thunk.
- Observed types must be `Sendable`. Every bridged property satisfied this already (primitives and value-type collections), so the constraint was free.
- Requires Swift 6.2+. The Android SDK ships the runtime with the app, so the OS floor on Android is unchanged; the bridge target's package manifest no longer compiles on a 6.0 toolchain, but this only matters for the Android-only bridge module.
- `Observations` rules out custom transaction boundaries (you can't ask it to emit on a specific point). For the bridge this was a non-issue: every transaction in the system is exactly one `@Observable` setter call cluster.

This survived as the bridge's observation primitive until SkipFuse adoption. SkipFuse intercepts `ObservationRegistrar` directly at the Swift `@Observable` macro level and routes the notifications into Compose's snapshot system without a Swift-side `for await` loop, so the per-binding `Task`s and the `Bridge.tasks` registry were deleted along with the rest of the hand-written bridge.
