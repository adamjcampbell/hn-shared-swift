# ADR-0012: Extension-method bridge experiment via swift-java jextract

## Status

Superseded by [ADR-0013](0013-skipfuse-bridgemembers.md) on 2026-05-10. The branch — `extension-method-bridge-experiment` — was created from main, explored the extension-method approach over a few commits, and never merged back. SkipFuse was adopted instead.

## Context

By 2026-05 the per-property bridge ([ADR-0007](0007-per-property-typed-jni-thunks.md)) plus its observation iterations ([ADR-0009](0009-observations-asyncsequence.md), [ADR-0010](0010-tuple-return-observe-read-fusion.md), [ADR-0011](0011-value-carrying-onchange-callbacks.md)) had reached a stable shape. The remaining friction was the per-property boilerplate: adding a new bridged field required:

1. A `@_cdecl` JNI getter thunk (e.g. `appcoreGetSearchQuery`).
2. A `@_cdecl` JNI observer thunk returning a tuple `(Int64, T)`.
3. Optionally a `@_cdecl` JNI setter for two-way fields.
4. A `BridgedSource<T>` declaration on the Kotlin side wrapping the thunk pair.
5. A typed `*OnChange` protocol if the value type didn't already have one.

Five touch points for one property. The thunks were all very similar — `JavaUIActor.assumeIsolated { Bridge.foo() }` shells around the actual `AppState` field — but they were hand-written and lived in a separate file.

`swift-java jextract` had matured to the point where it could extract method declarations from Swift `extension`s on classes and emit per-instance Java wrappers. If `AppState`'s bridge surface were expressed as instance extension methods — `func appcoreObserveSearchQuery(callback:) -> (Int64, String)` declared as `extension AppState { ... }` — jextract could generate the JNI thunks automatically, and the bridge would no longer need a hand-written `@_cdecl` file. The remaining boilerplate would be the extension methods themselves, but those would at least be in normal Swift code reading and writing actual `AppState` fields rather than `Bridge.foo()` shells.

The experiment landed on a side branch (`extension-method-bridge-experiment`) to validate this approach without disturbing the main bridge.

## Decision

On the branch:

- The `Bridge` namespace (the `@JavaUIActor`-isolated static surface that held the bridge's entry points) is gone.
- Per-property thunks become extension methods on `AppState`:

  ```swift
  extension AppState {
      public func appcoreObserveSearchQuery(callback: StringOnChange) -> (Int64, String) { ... }
      public func appcoreSetSearchQuery(value: String) { ... }
  }
  ```

- `jextract` runs over `AppCoreAndroid` and emits per-instance Java methods on the generated `AppState_Native` class.
- Observation lifetime is managed by the same `Bridge.tasks` registry but keyed off the `AppState` instance now visible at the call site.
- `Observations` AsyncSequence ([ADR-0009](0009-observations-asyncsequence.md)) and the tuple-return / value-carrying-callback patterns ([ADR-0010](0010-tuple-return-observe-read-fusion.md), [ADR-0011](0011-value-carrying-onchange-callbacks.md)) carry over unchanged.

The branch reached a working build but never merged.

## Consequences

- The boilerplate-per-property dropped from five touch points to three (extension method on Swift side, `BridgedSource<T>` on Kotlin side, optional setter). The biggest reduction was deleting the `Bridge` namespace entirely — it had been the largest single piece of the bridge layer.
- Each new property still required a hand-written extension method that called `Observations { ... }` and registered the Task in the registry. The `for await` loop body, the `(token, initial)` tuple assembly, the `register/cancel` plumbing — all still present, just moved into extension scope.
- `AsyncStream<T>`, collections of structs, `async` translation to Kotlin `suspend`, automatic `Codable` removal — none of these were addressed by the extension-method approach. The bridge was lighter, but not qualitatively different.
- The cancellation contract (Kotlin `coroutineCancellation` → Swift Task) still relied on `suspendCancellableCoroutine` plus the bespoke `appcoreCancelTask(token)` JNI thunk — no upstream support, all hand-written.

In parallel with this experiment, the SkipFuse evaluation ([ADR-0013](0013-skipfuse-bridgemembers.md)) crystallised. SkipFuse offered the same ergonomic improvements *and* solved the things the extension-method approach didn't: `AsyncStream` ↔ `Flow`, struct collections, `async` ↔ `suspend`, opaque pointer pass-through. The extension-method branch was abandoned without merging; the bridge code on main went directly from the per-property thunk surface to SkipFuse's `@bridgeMembers`.

The branch is preserved in git as `extension-method-bridge-experiment` so the design is recoverable. It is useful as a record of one direction the project considered and rejected.
