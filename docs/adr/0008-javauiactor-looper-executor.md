# ADR-0008: `JavaUIActor` pinned to Android's main `Looper` via custom `SerialExecutor`

## Status

Superseded by [ADR-0013](0013-skipfuse-bridgemembers.md) on 2026-05-10. The entire hand-written bridge — `JavaUIActor`, `LooperExecutor`, the `Bridge` namespace, every `@_cdecl` thunk — was dropped when SkipFuse was adopted. The migration plan initially abandoned per-platform actor pinning entirely; [ADR-0014](0014-mainactor-both-platforms.md) is a separate, later decision that re-introduced `@MainActor` once it became clear SkipFuse's codegen is actor-aware. ADR-0014 does **not** supersede this ADR — by the time it was made, `JavaUIActor` was already gone.

## Context

The hand-written Android bridge owned a non-`Sendable` `AppState` reference that was reachable from two places:

- JNI mutation entry points (`appcoreDispatch`, `appcoreSetSearchQuery`, etc.), each called synchronously from a JVM thread.
- The `Observations` task that watched `AppState` and pushed snapshots through `SnapshotSink`.

Under Swift 6 region isolation (SE-0414), a non-`Sendable` reference can live in only one concurrency region. The two access paths needed to be in the same region or the compiler would reject the design. An actor was the natural fit, with the JNI entry points either:

- Spawning `Task { await bridge.foo() }` and returning immediately to Kotlin (fire-and-forget), or
- Using `Actor.assumeIsolated { ... }` to enter the actor synchronously when the calling thread is guaranteed to be the actor's executor.

The second path requires the actor's executor to *be* the JVM thread that's calling. Apple's `MainActor` schedules onto libdispatch's main queue; Android doesn't drain libdispatch by default. So `MainActor.assumeIsolated` from a Kotlin-driven JNI thunk traps with "expected MainActor".

The constraint: Compose calls the JNI thunks from Android's main `Looper` thread. The bridge needed an actor whose executor *is* that thread, so that JNI mutations could run synchronously without a fire-and-forget gap.

## Decision

A custom global actor — `JavaUIActor` — backed by a hand-written `SerialExecutor` (`LooperExecutor`) that posts jobs to Android's main `Looper` via JNI (`Handler(Looper.getMainLooper()).post { ... }`).

```swift
public actor JavaUIActor {
    public static let shared = JavaUIActor()
    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        LooperExecutor.shared.asUnownedSerialExecutor()
    }
    public static func assumeIsolated<T>(_ op: @JavaUIActor () throws -> T) rethrows -> T { ... }
}
```

The Bridge namespace and all bridge primitives (`AndroidSnapshot`, `AndroidBinding`, `AndroidCommands`) are isolated to `@JavaUIActor`. JNI thunks enter the actor synchronously via `JavaUIActor.assumeIsolated { Bridge.foo() }` because Compose always calls them from the main `Looper` thread, which *is* the actor's executor.

Async dispatch (e.g. `appcoreDispatch` for `Message`s that need to `await` something) uses a separate `enqueueDispatch` method that internally spawns a `Task` on the actor — preserving sync return + async completion semantics, mirroring iOS's `SendMessageAction.callAsFunction(_:)` / `.run(_:)` split.

## Consequences

- JNI mutations are strict-sync. By the time the JNI call returns to Compose, the mutation has taken effect on the Swift side.
- Snapshot delivery (Observations → sink) runs on the same `Looper`, so Compose `MutableState` updates land directly on the UI thread without an internal cross-thread post.
- A future background-coroutine caller of a bridged thunk would trap (`Incorrect actor executor assumption`), which is the right failure mode — silently re-scheduling onto a different thread would hide a real bug. If a future use case genuinely needs an off-UI JNI caller, a separate variant should wrap the actor call in `Task { await ... }`; the `assumeIsolated` contract should not be relaxed.
- The `LooperExecutor` body, the `unownedExecutor` override, and the `assumeIsolated` workaround are all hand-written. They are non-obvious — `MainActor.assumeIsolated` is special-cased in the stdlib and a custom global actor's version has to be written explicitly.
- This pattern is not covered by `swift-java`, by Skip's published documentation, or by any other reference implementation at the time of writing. It is one of the bridge's most novel contributions and was identified as worth contributing upstream as a standalone `swift-android-actor` package.

The migration to SkipFuse made this entire mechanism redundant: SkipFuse's runtime registers libdispatch's main queue with Android's `ALooper` at app startup, so jobs scheduled to `MainActor` execute on the main looper thread automatically. The `assumeIsolated` machinery the stdlib already special-cases for `MainActor` now Just Works on Android, and the hand-written equivalent was deleted.
