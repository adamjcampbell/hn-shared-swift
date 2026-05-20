# ADR-0014: Pin the bridged `Core` to `@MainActor` on both platforms

## Status

Accepted (2026-05-13).

## Context

The previous bridge ([ADR-0008](0008-javauiactor-looper-executor.md)) pinned the Android-side `AppState` to a hand-written `JavaUIActor` whose `SerialExecutor` posted jobs to Android's main `Looper` via JNI. iOS used `@MainActor` directly. Two different global actors covered the two platforms with materially different machinery.

When SkipFuse was adopted ([ADR-0013](0013-skipfuse-bridgemembers.md)) the entire hand-written bridge was deleted, including `JavaUIActor`. The migration plan initially **abandoned per-platform actor pinning entirely** on the assumption that SkipFuse couldn't handle actor-isolated bridged classes — the assumption was based on earlier experiments where adding `@JavaUIActor` to a jextract'd model class produced ~20 compile errors in the auto-generated cdecl thunks.

Three days after SkipFuse landed (2026-05-13) it became clear the assumption was wrong. `skipstone` (SkipFuse's code generator) is fully actor-aware. Annotate a bridged class with `@MainActor` and every generated cdecl thunk's body gets wrapped in `SkipBridge.assumeMainActorUnchecked { ... }`, which is `MainActor.assumeIsolated`. Async dispatches stay simple — `Task { await peer.sendMessage(...) }` hops to `MainActor` automatically under SE-0461.

`MainActor` on Android works because Skip's `swift-android-native` runtime bridges Apple's `MainActor` semantics to Android's main thread at startup. `MainActor` schedules onto libdispatch's main queue; Skip's `AndroidLooper.setupMainLooper()` (called from `AndroidBridgeBootstrap.initAndroidBridge()` at app launch — visible in logcat as `swift.android.native/AndroidLooper: setupMainLooper`) registers libdispatch's main queue file descriptor with Android's `ALooper`. When the main queue has work, `CFRunLoopRunInMode(...)` drains both CFRunLoop and the dispatch main queue. Net effect: jobs scheduled to `MainActor` execute on Android's main looper thread, the same place Compose dispatches all UI events from.

The runtime guarantees:

- Compose UI-thread calls into bridged thunks land on the main looper, which **is** `MainActor`'s executor — the `assumeIsolated` precondition passes and the access succeeds.
- A background-thread JNI call (e.g. a `Dispatchers.IO` coroutine accidentally invoking a bridged member) traps with `Incorrect actor executor assumption; expected MainActor` — the same dynamic check the old `JavaUIActor.assumeIsolated` did.

This is the same trick the hand-written `JavaUIActor` + `LooperExecutor` pulled, except `MainActor` is the stdlib's standard global actor with stdlib-blessed `assumeIsolated` and SkipFuse's runtime provides the looper-to-libdispatch bridging upstream.

## Decision

`Core` is a `@MainActor struct` bridged via `// SKIP @bridgeMembers`. Its `let` fields hold the `Model` class, the `commands: AsyncStream<Command>`, and the `sendMessage: SendMessageAction`. `makeCore()` is `@MainActor`. `Model` itself is a plain `@Observable final class` with no isolation annotation; its mutation discipline is enforced by the writer (see [ADR-0015](0015-engine-borrows-host-executor.md) and [ADR-0016](0016-engine-actor-flat-model.md)), not by an actor annotation on `Model`. The writer is an `actor Engine` that borrows `MainActor.shared`'s executor in production, so calls into `Engine` from `MainActor`-isolated code paths are virtual hops that never leave the main thread.

No per-platform actor annotation. No custom `LooperExecutor`. No hand-written `assumeIsolated` workaround.

## Consequences

- One actor annotation works on both platforms. iOS and Android share the same isolation story end-to-end.
- Compile-time isolation safety is restored. Background-thread access to bridged state is caught by the compiler (where the call site has a known different isolation) or by the runtime check inside `assumeMainActorUnchecked` (where it doesn't).
- The hand-written `JavaUIActor` and `LooperExecutor` are deleted along with the rest of the hand-written bridge — see [ADR-0008](0008-javauiactor-looper-executor.md). This ADR doesn't supersede that one; it's a fresh decision made in the SkipFuse world. The hand-written executor was already dead when this decision was made.
- Skip's `swift-android-native` registers the looper bridge at app startup, so the cost of `MainActor` on Android is a fixed one-time bootstrap rather than per-call overhead.
- `MainActor` works for this project because the entire core is single-threaded and UI-bound — no background pipeline, no off-thread work. A future high-throughput core (e.g. a media transcoder driving the model) would need an off-main isolation domain alongside, but the bridge surface — what crosses JNI — would still want `@MainActor` for the same reason: Compose draws from the main thread.
- The `JavaUIActor` lineage is preserved in the repo's git history and in [ADR-0008](0008-javauiactor-looper-executor.md). It is useful as evidence that the architectural problem is real and that the upstream solution (Skip's runtime) and the hand-written one (the custom executor) both work — they just have very different maintenance profiles.
