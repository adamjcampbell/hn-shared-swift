# ADR-0010: Tuple-return fusion of `observe` and initial read

## Status

Superseded by [ADR-0013](0013-skipfuse-bridgemembers.md) on 2026-05-10. SkipFuse-generated property accessors expose the initial value at the same time the binding is registered, so the hand-written `(Int64, T)` tuple-return thunks are gone.

## Context

A single observation registration ([ADR-0009](0009-observations-asyncsequence.md)) needed to deliver two pieces of information back to Kotlin in one construction step:

1. The **cancellation token** — an `Int64` naming the registered `Task` in `Bridge.tasks`, used later by `appcoreCancelTask(token)`.
2. The **initial value** of the observed property, so the Kotlin-side `MutableState` could be seeded with the current state at construction time.

Three shapes were on the table:

| Shape | Round-trips at construction |
|---|---|
| Two thunks: `appcoreObserveX → token`, then a separate read thunk for the initial value | 2 K→S |
| One thunk + a Kotlin-implemented `Subscription` callback that fires inline with the token | 1 K→S + 1 inner S→K |
| One thunk returning a Swift tuple `(Int64, T)` | 1 K→S |

The first shape (two thunks) was the original implementation. Each binding paid an extra JNI read at construction to fetch the initial value, on top of the register-and-get-token call. Adding `BridgedSource<T>`s in tests showed the construction cost growing linearly — not a bottleneck, but visibly wasteful.

The second shape (Subscription callback) replaced the second read with an inline callback Kotlin passes to `appcoreObserveX(onChange:, subscription:)`. The Swift side fires `subscription.attached(token:)` synchronously inside the thunk; Kotlin captures the token in a closure-scoped `var`. This worked but added a `Subscription` protocol, a `JavaSubscription: @unchecked Sendable` typealias, a `var capturedToken = -1L; … ; token = capturedToken` dance at every observe call site, and a synchronous inner S→K callback per construction.

`jextract`'s JNI mode supports Swift tuple returns directly. For `func appcoreObserveX(callback: SomeOnChange) -> (Int64, Bool)`, it generates a Java wrapper that allocates out-param arrays and assembles them into a `Tuple2<Long, Boolean>` from the `swiftkit-core` dependency the bridge already pulls in. The Kotlin call site reads `val (token, initial) = swiftState.observe(callback)` via component-extension operators.

## Decision

Per-property observe thunks return Swift tuples `(Int64, T)`. Kotlin destructures them naturally:

```kotlin
val (token, initial) = swiftState.observe(OnChange { state.value = it })
```

The `Subscription` protocol, the `JavaSubscription: @unchecked Sendable` typealias, the `capturedToken` dance, and the second read thunk are all deleted.

## Consequences

- Exactly one Kotlin → Swift round-trip per binding registration. No inner callback, no separate read, no `@unchecked Sendable` typealias.
- The construction call site is idiomatic Kotlin destructuring; reader can verify correctness at a glance.
- One `Tuple2` Java allocation per registration, plus boxing for primitive tuple slots. `Boolean.valueOf` is cached; `Long.valueOf` caches `[-128, 127]` only, so each token (which monotonically increases) misses the cache and allocates a `Long` box. For five bindings created once at app startup this is ~10 small allocations total — invisible. For a future high-frequency case it would matter; the `Subscription` shape would be marginally cheaper because it returns primitives directly.
- The pattern generalises: `Tuple3<…>` / `Tuple4<…>` work the same way if a future thunk needs to deliver three or more pieces. swiftkit-core supports up to `Tuple21`.

When the bridge was replaced by SkipFuse, the Compose state cell for each `@Observable` property exposes the current value directly through the generated accessor, and the long-lived observation Task that owned the token disappeared. The tuple-return shape no longer applies to anything in the codebase — it lives on only as the explanation for why one specific class of redundant JNI round-trip used to exist and how it was eliminated.
