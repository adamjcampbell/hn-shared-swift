# ADR-0013: Adopt SkipFuse with `// SKIP @bridgeMembers` for whole-class bridging

## Status

Accepted (2026-05-10).

## Context

By 2026-05-10 the hand-written `swift-java jextract` bridge had reached a working steady state with roughly 1,180 lines of Swift across `AppCoreAndroid` plus matching Kotlin glue. The bridge correctly handled:

- A single `@Observable` `AppState` as the source of truth ([ADR-0001](0001-observable-model-source-of-truth.md)).
- Per-property typed JNI thunks for each observable field ([ADR-0007](0007-per-property-typed-jni-thunks.md)).
- A custom `JavaUIActor` + `LooperExecutor` pinning Swift actor isolation to Android's main thread ([ADR-0008](0008-javauiactor-looper-executor.md)).
- `Observations` AsyncSequence-driven per-property observation, post-`didSet` ([ADR-0009](0009-observations-asyncsequence.md)).
- Tuple-return registration ([ADR-0010](0010-tuple-return-observe-read-fusion.md)) and value-carrying callbacks ([ADR-0011](0011-value-carrying-onchange-callbacks.md)).

What worked: every piece was readable, auditable, and aligned with the official Swift/Android path. What didn't: every new `@Observable` property required ~30 lines of Swift across three files plus ~4 lines of Kotlin. `AsyncStream<T>` ↔ `Flow<T>` was hand-rolled per stream. Arrays of structs (`[Story]`) crossed as JSON-encoded strings because jextract's struct support wasn't there yet. Kotlin coroutine cancellation didn't propagate to the Swift `Task` — `suspendCancellableCoroutine` plus a bespoke `appcoreCancelTask` registry filled the gap. The extension-method experiment ([ADR-0012](0012-extension-method-bridge-jextract.md)) reduced the boilerplate per property but didn't address the structural gaps.

SkipFuse (Skip Tools' native-Swift + auto-generated JNI layer) had been evaluated in parallel. The headline shape: mark a Swift type with `// SKIP @bridgeMembers` and the `skip-bridge` build plugin generates all JNI glue — field accessors, observation routing, `AsyncStream<T>` → `Flow<T>` projection, `async` → `suspend` translation, opaque-pointer pass-through for reference types. The Kotlin side reads the Swift class as if it were a Kotlin class. `@Observable` notifications are intercepted at the `ObservationRegistrar` level and routed into Compose's `MutableStateBacking` snapshot system — Compose recomposes automatically when a Swift property mutates. No hand-written `for await` loop, no callback protocol, no `BridgedSource<T>`, no Kotlin holder.

The trade-off is licensing and inspection. SkipFuse is free for indie developers (as of late 2025); commercial licensing applies to enterprise use. The generated bridge code lives outside the project's tree, so debugging through it is less direct than reading hand-written `@_cdecl` thunks. The mature SwiftUI-on-Android layer (SkipUI) is also available but not used here — Android UI stays idiomatic Compose per [ADR-0002](0002-per-platform-ui-no-sharing.md).

## Decision

Replace the hand-written Android bridge module with SkipFuse. Annotate the bridged Swift types — `Core`, `Model`, `SendMessageAction`, and the HN domain types — with `// SKIP @bridgeMembers`. Use `// SKIP @nobridge` to opt single members out when they take unbridged parameter types. Delete the `Bridge` namespace, `AndroidSnapshot`, `AndroidBinding`, `AndroidCommands`, `JavaUIActor`, `LooperExecutor`, the `Bridge.tasks` registry, the typed `*OnChange` protocols, and the Kotlin `SwiftState` holder. Build the Android target with the Gradle `skipExport` task that re-runs `skip export` whenever Swift sources change.

The wire surface stops being JSON. Reference types cross JNI as opaque `Int64` pointers (`SwiftObjectPointer`); their fields are read on demand through generated per-property JNI accessors. `[Story]` becomes a peer-backed Kotlin list whose elements are peer-backed Kotlin objects — each element field access crosses JNI individually. `AsyncStream<Command>` exposes a `.kotlin()` projection that returns a Kotlin `Flow<Command>`. Async functions surface as Kotlin `suspend fun`s automatically.

## Consequences

- Bridge code drops from roughly 1,180 hand-written Swift lines (the `AppCoreAndroid` target's `Bridge`, `AndroidSnapshot`, `AndroidBinding`, `AndroidCommands`, `JavaUIActor`, `LooperExecutor`, `@_cdecl` thunks, and matching Kotlin holder) to a small set of `// SKIP @bridgeMembers` annotations plus the launch-time SkipFuse bootstrap. The bridged Swift target itself is no longer a separate `AppCoreAndroid` module — bridging markers live alongside the regular Swift declarations.
- Adding a new `@Observable` property is one Swift line on `Model`. No Kotlin holder change. No thunk. No protocol.
- `@MainActor`-isolated bridged classes work without hand-written executor pinning — see [ADR-0014](0014-mainactor-both-platforms.md) for the actor isolation story after this change.
- The build now requires Kotlin 2.3.x to match SkipFuse's exported AAR metadata, plus `kotlin-reflect` at runtime for the launch-time bridge bootstrap. Mismatches surface as `Class … was compiled with an incompatible version of Kotlin` or `ClassNotFoundException` on cold start.
- `suspend fun` uses `suspendCoroutine`, not `suspendCancellableCoroutine`. Kotlin coroutine cancellation does **not** propagate back to the Swift `Task`. The bespoke `appcoreCancelTask` registry that used to bridge cancellation is gone; for dispatches that need cooperative cancellation (e.g. pull-to-refresh cancelled by navigation away from the screen) the cancellation has to be wired manually or accepted as a leaked Task. This is the most significant capability regression vs. the hand-written bridge.
- Each `Story` field read crosses JNI individually. For the ~200-row HN front page this is comfortably fast. For a chat-app-scale collection (tens of thousands of rows) the per-field JNI cost would warrant Skip's custom value-class projections; that's not in scope here.
- The generated bridge code is opaque relative to the hand-written one. Debugging into bridged behaviour is less direct; logs and integration tests carry more of the verification weight than they did before.
- The license dependency is real but free for this project's scope. The choice to take it is informed by the time-cost vs. functionality trade-off: hand-writing the equivalent of SkipFuse's `AsyncStream` ↔ `Flow`, struct collections, and registrar interception would be a multi-week effort with no clear architectural payoff.

The decision was empirically verified before landing: clean `swift build`, clean `skip export` (which `skipstone` runs against the Swift sources), clean `./gradlew :app:assembleDebug`, an APK that boots and behaves end-to-end identically to the hand-written-bridge version. Several downstream decisions ([ADR-0014](0014-mainactor-both-platforms.md), [ADR-0015](0015-engine-borrows-host-executor.md), [ADR-0016](0016-engine-actor-flat-model.md)) became possible only after this one was made.
