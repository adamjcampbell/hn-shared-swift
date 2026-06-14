# ADR-0026: Replace the `TaskRegistry` with a per-surface `Latest` slot; async caller-following `apply`

## Status

Accepted (2026-06-14). Supersedes [ADR-0025](0025-inject-registry-static-production-isolation.md) and [ADR-0021](0021-spawn-owning-task-registry.md) (the spawn-owning `TaskRegistry`), and [ADR-0022](0022-observable-task-registry-test-signal.md) (observing that registry as a test signal). Amends [ADR-0019](0019-core-free-functions-uicore-split.md): the free-function core and the vend-one-`Core` boundary stand, but `apply` becomes `async` and the registry it threaded is gone.

## Context

[ADR-0025](0025-inject-registry-static-production-isolation.md) had `makeCore` inject a `TaskRegistry<TaskID>` whose spawner carried the caller's isolation. The registry was a keyed (`feed` / `feedMore` / `search` / `searchMore` / `searchListener`) store of in-flight `Task`s with cancel-and-replace, and `apply` was **synchronous**, returning the spawned `Task` so `.refreshable` could await it.

The registry existed because a synchronous `apply` cannot `await`. Every fetch had to be handed to a spawner that ran it on the host actor — not because fetching needs the host actor, but because the work also *committed* the fetched page into the non-`Sendable` `Model`, which must happen there. The registry conflated two jobs: running the fetch (isolation-agnostic) and mutating the `Model` (host-actor-only).

Two observations reopened the design:

- If `apply` were `async` and caller-following (SE-0461, already the package default), it could `await` the fetch and commit the `Model` in place on the host actor, with no per-fetch spawn for the commit.
- A fetch is a function over `Sendable` values: a request closure in, a `Page` out. Split the fetch from the commit and the fetch needs no isolation at all. The host-actor capability is then needed only where work must both run *and* mutate the `Model`.

## Decision

**`Latest<Value>` replaces the registry.** A non-`Sendable`, host-actor-confined single-slot primitive: each call cancels the operation still in flight and runs the new one in its place. It brokers only `Sendable` values, so its in-flight `Task` runs the fetch off the host actor; the caller commits the value it returns.

```swift
final class Latest<Value: Sendable> {
    private var inFlight: Task<Value, Error>?
    func callAsFunction(_ work: @Sendable @escaping () async throws -> Value) async throws -> Value {
        inFlight?.cancel()
        let task = Task { try await work() }
        inFlight = task
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard inFlight == task else { throw CancellationError() }   // latest-wins at delivery
        return value
    }
    func cancel() { inFlight?.cancel(); inFlight = nil }
}
```

Latest-wins is enforced **at delivery**, not by cancellation alone. `cancel()` only requests cooperative cancellation, so a fetch whose round-trip completes before the cancel is observed would otherwise hand its value to a superseded caller. The post-await `inFlight == task` check throws `CancellationError` for a superseded caller regardless of whether its work honoured the cancel, so callers commit unconditionally without their own staleness guard.

**`apply` is `async` and caller-following.** It commits the `Model` in place after the await and no longer returns a `Task`; `.refreshable` awaits `apply` directly. Each fetch arm performs its read-modify-write before the first `await`, so it stays atomic against actor reentrancy, and the post-fetch commit resumes back on the host actor.

**The feed shares one `Latest` slot for its initial load and its load-more.** Both run through it, so a refresh cancels an in-flight load-more intrinsically — the explicit cross-slot `cancel(.feedMore)` ADR-0025 needed is gone. A `!feedInitialStatus.isLoading` guard makes a load-more yield to a refresh rather than cancel the reload it shares the slot with.

**Search is unified with the feed: one `search` slot, an apply-shaped arm.** The search reload is `applySearch(query:to:search:)`, shaped exactly like an `apply` fetch arm (`await load` over the `search` slot), and the search load-more (`apply`'s `.loadMore`) shares that same slot — so a new query cancels an in-flight load-more intrinsically, the mirror of feed. Search stays binding-driven: the field writes `model.searchQuery`, and a thin long-lived driver (`runSearch`) reads `searchQueryChanges` and *spawns* an `applySearch` per query change (spawning rather than awaiting, so the driver keeps reading the next keystroke while a reload is in flight). Each reload commits the `Model`, so it runs on the host actor via the injected `spawn` — `makeCore` takes a `spawn` parameter (the same isolation-carrying spawner ADR-0025 injected: static `@MainActor` in production, `_ = isolation` capture in tests), used for the driver and each reload it spawns. The awaited feed and search-load-more paths use `Latest` directly and need no spawner.

**Order-safety rests on SE-0431, not a held handle.** The per-query tasks `runSearch` spawns enqueue their initial job in creation order on the host actor (SE-0431: same-priority tasks whose closures are isolated to the same executor begin executing in creation order), and each claims the `search` slot in its *synchronous head* — before its first real suspension (`await task.value` on the inner fetch). So they occupy the slot in query order, and `Latest`'s delivery guard lets only the last (newest) commit. This is the same ordering the `feed` slot already relies on; for search it is load-bearing. The invariant is unenforced by types — the slot must be claimed in the synchronous head, the spawned closure must stay host-actor-isolated, and priority must stay uniform (nothing `await`s an older reload's value) — and is noted in `applySearch`.

So the capability to start a `Task` on an isolation that may mutate the `Model` is retained, scoped to the one path that genuinely needs it, instead of mediating every fetch.

## Consequences

- `TaskRegistry`, `TaskID`, and the keyed cancel-and-replace store are removed. Two `Latest` slots (`feed`, `search`) replace them — one per list, each shared by that list's initial load / reload and its load-more.
- The cooperative-cancel race is closed in one place — the `Latest` delivery guard — rather than per call site. A load-more whose round-trip completes after being superseded no longer appends a stale page or desyncs the pagination cursor.
- `apply` no longer returns a `Task`. `.refreshable` holds its spinner by awaiting the fetch through `apply` itself.
- Cross-surface cancellation is intrinsic to each shared slot: a refresh cancels an in-flight feed load-more, and a new query cancels an in-flight search load-more, because both run through their list's one `Latest`. No explicit cross-slot `cancel` remains (a `!initialStatus.isLoading` guard makes a load-more yield to a refresh / reload rather than cancel it).
- The injected spawner is used only for the search driver and the reloads it spawns — not for feed refresh, feed load-more, or search load-more, which go through `Latest`. The isolation-capture spelling is unchanged from ADR-0025, now confined to that one path. This is where "start a task on an isolation that mutates the model" earns its place; everywhere else the `Sendable` `Latest` suffices.
- Tests no longer observe the registry (ADR-0022). They await `Model` transitions via `waitUntil`, or the awaited `apply`. `Latest` carries its own unit tests, and a cancellation-ignoring `Hold` test helper reproduces the cooperative-cancel race the delivery guard prevents.
- The search reload has no bespoke staleness guard: it goes through the shared `search` slot, so a superseded reload throws via `Latest`'s delivery guard (authoritative — it fires even if the work completed, so it is robust to a same-string re-type, with no purity assumption). Combined with the SE-0431 occupation order, the newest query is the only committer.
- [ADR-0023](0023-ambient-debounce-clock-free-tests.md)'s ambient `searchDebounce` and [ADR-0020](0020-ambient-dependencies-struct.md)'s ambient `Dependencies` are unchanged: the reload calls `fetch(debounce:)`, reading `Dependencies.current`.

## Alternatives considered

**Keep a merge-stream search consumer with a `Sendable` reload.** An earlier form of this change kept the reload `Sendable` by routing it through a second `AsyncStream`: the reload `Task` did only the fetch and yielded its page back as an event the consumer committed, with a forwarder `Task` bridging `searchQueryChanges` into the event stream. It avoided spawning a `Model`-mutating reload — but the host-actor spawner was retained anyway (to start the consumer), so the purity bought nothing and cost an event enum, a second stream, and a forwarder task. Rejected: once the spawner is already present, using it for the reload collapses the consumer to a plain cancel-and-replace loop, and the capability is used only where the work genuinely mutates the `Model`.

**Per-arm staleness guards on each load-more commit.** Guard each commit with `query == state.searchQuery` (search) or a cursor check (feed) instead of fixing `Latest`. Rejected: the feed cursor check is insufficient — a refreshed page-0 snapshot carries the same page number as the one being appended onto — and the `Latest` delivery guard fixes both load-more surfaces at the primitive's own boundary, in one place.

**A synchronously-cancelled handle for the search reload (no SE-0431 reliance).** The reload could stay in the driver as a held `Task` cancelled synchronously in the loop (`reload?.cancel(); reload = spawn { … }`) plus a post-fetch `checkCancellation`, which is order-safe *without* depending on task start-order — the prior occupant is cancelled before the next is spawned, in stream order. Rejected for the unified form: it keeps search a bespoke consumer loop rather than an apply-shaped arm, and duplicates the cancel-and-replace the `search` slot already does. The cost of the chosen form is that search-keystroke correctness now leans on SE-0431's ordering guarantee — but `feed` already leans on it, the guarantee is specified (not an implementation detail), and the win is one shape for both lists. Kept as the documented fallback if that reliance ever becomes untenable.

**Message-driven search.** Dispatch a `.search(query)` message per keystroke instead of binding `model.searchQuery`. Each `SendMessageAction.send` already spawns its own non-blocking `Task`, so search would join the awaited-`apply`-commits path and the host-actor spawner could be removed entirely. Rejected to keep search binding-driven: the text field binds `model.searchQuery` and the Android `BridgedSource` write-through is built for it. The spawner is retained for the one consumer instead.
