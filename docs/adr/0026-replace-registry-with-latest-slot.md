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

**Search stays binding-driven, and is the one place the host-actor spawner is kept.** The search field writes `model.searchQuery`; one long-lived host-isolated consumer reads its changes and spawns each reload. The reload must run *and* commit the `Model` while new queries keep arriving, so it can be neither an awaited `Latest` (that would block the consumer) nor `Sendable` (it mutates the `Model`). `makeCore` therefore takes a `spawn` parameter — the same isolation-carrying spawner ADR-0025 injected (static `@MainActor` in production, `_ = isolation` capture in tests), now used only for the consumer and its reloads. The awaited feed and search-load-more paths use `Latest` and need no spawner.

So the capability to start a `Task` on an isolation that may mutate the `Model` is retained, scoped to the one path that genuinely needs it, instead of mediating every fetch.

## Consequences

- `TaskRegistry`, `TaskID`, and the keyed cancel-and-replace store are removed. Per-surface `Latest` slots (`feed`, `searchMore`) replace them; the search reload is a held `Task` in the consumer.
- The cooperative-cancel race is closed in one place — the `Latest` delivery guard — rather than per call site. A load-more whose round-trip completes after being superseded no longer appends a stale page or desyncs the pagination cursor.
- `apply` no longer returns a `Task`. `.refreshable` holds its spinner by awaiting the fetch through `apply` itself.
- Cross-surface cancellation is intrinsic for the feed (the shared slot); for search a new query cancels the `searchMore` slot explicitly in the consumer.
- The injected spawner is used only for the search consumer and its reloads — not for feed refresh, feed load-more, or search load-more, which go through `Latest`. The isolation-capture spelling is unchanged from ADR-0025, now confined to that one path. This is where "start a task on an isolation that mutates the model" earns its place; everywhere else the `Sendable` `Latest` suffices.
- Tests no longer observe the registry (ADR-0022). They await `Model` transitions via `waitUntil`, or the awaited `apply`. `Latest` carries its own unit tests, and a cancellation-ignoring `Hold` test helper reproduces the cooperative-cancel race the delivery guard prevents.
- The search reload's staleness guard is the post-fetch `try Task.checkCancellation()` in the cancelled reload `Task`. Because a reload does a full *replace* (not an append), a result that completes inside the cancellation race window is transient — the latest reload commits last. This assumes `search(query, 0)` is a pure function of `query`: a same-string re-type while a fetch is in flight could briefly show the prior, identical result. For the search backend in use this is unobservable, and a generation-token guard (which cannot be tested deterministically) is not warranted.
- [ADR-0023](0023-ambient-debounce-clock-free-tests.md)'s ambient `searchDebounce` and [ADR-0020](0020-ambient-dependencies-struct.md)'s ambient `Dependencies` are unchanged: the reload calls `fetch(debounce:)`, reading `Dependencies.current`.

## Alternatives considered

**Keep a merge-stream search consumer with a `Sendable` reload.** An earlier form of this change kept the reload `Sendable` by routing it through a second `AsyncStream`: the reload `Task` did only the fetch and yielded its page back as an event the consumer committed, with a forwarder `Task` bridging `searchQueryChanges` into the event stream. It avoided spawning a `Model`-mutating reload — but the host-actor spawner was retained anyway (to start the consumer), so the purity bought nothing and cost an event enum, a second stream, and a forwarder task. Rejected: once the spawner is already present, using it for the reload collapses the consumer to a plain cancel-and-replace loop, and the capability is used only where the work genuinely mutates the `Model`.

**Per-arm staleness guards on each load-more commit.** Guard each commit with `query == state.searchQuery` (search) or a cursor check (feed) instead of fixing `Latest`. Rejected: the feed cursor check is insufficient — a refreshed page-0 snapshot carries the same page number as the one being appended onto — and the `Latest` delivery guard fixes both load-more surfaces at the primitive's own boundary, in one place.

**Message-driven search.** Dispatch a `.search(query)` message per keystroke instead of binding `model.searchQuery`. Each `SendMessageAction.send` already spawns its own non-blocking `Task`, so search would join the awaited-`apply`-commits path and the host-actor spawner could be removed entirely. Rejected to keep search binding-driven: the text field binds `model.searchQuery` and the Android `BridgedSource` write-through is built for it. The spawner is retained for the one consumer instead.
