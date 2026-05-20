# ADR-0007: Per-property typed JNI thunks (replaces JSON-snapshot push)

## Status

Superseded by [ADR-0013](0013-skipfuse-bridgemembers.md) on 2026-05-10. SkipFuse generates the equivalent per-property accessors automatically as part of `// SKIP @bridgeMembers`, so the hand-written `appcoreObserve*` / `appcoreGet*` thunks were deleted.

## Context

The previous bridge ([ADR-0004](0004-json-snapshot-push.md)) encoded the entire `AppState` to JSON on every transaction and pushed the string across JNI. That worked but had three escalating problems:

1. **Encoding cost grew with payload size.** The cities demo's ~340-byte snapshot was invisible. The Hacker News pivot grew the payload to ~10–30 KB per snapshot, dominated by `[Story]`. Every observed change paid full encode cost regardless of which field changed.
2. **Coarse-grained recomposition.** The Kotlin side held one `MutableState<Snapshot?>` for the whole `AppState`. A Composable that read only `searchQuery` recomposed on every `stories` update because they shared the snapshot cell.
3. **Two-way bindings were awkward.** The search field was a two-way binding (Compose writes user input; Swift reads it). With the snapshot push approach the write went through `Message`, the read came back through the snapshot — a round-trip with no native equivalent to a Compose `MutableState<String>`.

By 2026-05 the `swift-java jextract --mode=jni` tool had matured enough to bridge a wider set of types: primitives, strings, primitive arrays, and increasingly structured types. Per-property JNI accessors became practical.

## Decision

Replace the single JSON-snapshot path with per-property typed JNI thunks. Each `@Observable` field on `AppState` gets:

- An `appcoreGet<Field>()` `@_cdecl` thunk returning the value typed (e.g. `String` for `searchQuery`, `Bool` for `isLoading`, a boxed `[Story]` for `stories`).
- An `appcoreObserve<Field>(callback)` `@_cdecl` thunk that registers a per-property observation and fires `callback.onChange(value:)` on each change.

The Kotlin side wraps each thunk pair in a `BridgedSource<T>` that exposes a Compose `MutableState<T>` via `produceState` + listener. Composables that read `searchQuery` only recompose when `searchQuery` changes; the same is true for every other field.

Per-property writes use a setter thunk (`appcoreSetSearchQuery(value:)`) called from Compose; the write is dedup'd against the most-recent Swift-side value to avoid echo loops between the two sides of a two-way binding.

JSON survives where it makes sense: structured collections that don't yet bridge cleanly (`Set<String>` for read-story ids) and `Command` payloads still use JSON. Scalars and simple lists are bridged typed.

## Consequences

- Compose recomposition becomes field-granular. A search-field keystroke no longer recomposes the entire story list.
- Encoding cost drops for the common case (one field changed → one typed value crosses JNI) and is zero for cache hits on the Kotlin side.
- The bridge surface grows linearly with the number of bridged fields: each new `@Observable` property is one thunk pair (getter + observer) on the Swift side, one `BridgedSource<T>` declaration on the Kotlin side, and an optional setter thunk for writable fields. The boilerplate-per-property is real and visible.
- The two-way binding problem is solved: `BridgedSource<String>` wraps the read and the write into a Compose `MutableState<String>` that the search field uses directly.
- The willSet race in Swift's observation framework — `withObservationTracking`'s `onChange` fires *inside* willSet, before the mutation has committed — becomes a problem to solve per-property rather than per-snapshot. That motivated the observation-mechanism iterations covered in [ADR-0009](0009-observations-asyncsequence.md), [ADR-0010](0010-tuple-return-observe-read-fusion.md), and [ADR-0011](0011-value-carrying-onchange-callbacks.md).
- The bridge is no longer "the snapshot is the contract"; it's "this set of thunks is the contract", and adding a property is a deliberate act with visible cost.

SkipFuse subsumed this entire surface a few days later by generating the per-property accessors automatically from `// SKIP @bridgeMembers` — same architectural shape, zero hand-written thunks.
