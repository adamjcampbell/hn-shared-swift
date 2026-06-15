# ADR-0026: Replace the `TaskRegistry` with a flat `Tasks` slot registry and free `latest` / `cancel`; async caller-following `apply`

## Status

Accepted (2026-06-15). Supersedes [ADR-0025](0025-inject-registry-static-production-isolation.md) and [ADR-0021](0021-spawn-owning-task-registry.md) (the spawn-owning `TaskRegistry`), and [ADR-0022](0022-observable-task-registry-test-signal.md) (observing that registry as a test signal). Amends [ADR-0019](0019-core-free-functions-uicore-split.md): the free-function core and the vend-one-`Core` boundary stand, but `apply` becomes `async` and the registry it threaded is gone.

## Context

[ADR-0025](0025-inject-registry-static-production-isolation.md) had `makeCore` inject a `TaskRegistry<TaskID>` whose spawner carried the caller's isolation. The registry was a keyed (`feed` / `feedMore` / `search` / `searchMore` / `searchListener`) store of in-flight `Task`s with cancel-and-replace, and `apply` was **synchronous**, returning the spawned `Task` so `.refreshable` could await it.

The registry existed because a synchronous `apply` cannot `await`. Every fetch had to be handed to a spawner that ran it on the host actor — not because fetching needs the host actor, but because the work also *committed* the fetched page into the non-`Sendable` `Model`, which must happen there. The registry conflated two jobs: running the fetch (isolation-agnostic) and mutating the `Model` (host-actor-only).

Two observations reopened the design:

- If `apply` were `async` and caller-following (SE-0461, already the package default), it could `await` the fetch and commit the `Model` in place on the host actor, with no per-fetch spawn for the commit.
- A fetch is a function over `Sendable` values: a request closure in, a `Page` out. Split the fetch from the commit and the fetch needs no isolation at all. The host-actor capability is then needed only where work must both run *and* mutate the `Model`.

## Decision

**A flat `Tasks` registry replaces the keyed registry.** It is a non-`Sendable`, host-actor-confined class of named `Task?` slots — `feed` and `search`, one per list — and nothing more: pure data, no methods. It is threaded as a parameter beside the `Model`, because both are the `Core`'s non-`Sendable` state; every read and write of a slot is a synchronous step on the host actor, so the cancel-and-replace needs no lock and no actor hop.

```swift
final class Tasks {
    var feed: Task<Page, Error>?
    var search: Task<Page, Error>?
}
```

**The latest-wins policy lives in two free functions, not a wrapper type.** A slot is just a `Task` cell; the only thing that is *not* already a `Task` is the cancel-and-replace policy, written once and shared by the four call sites (feed refresh, feed load-more, search reload, search load-more). The functions are generic over the slot's class and value, so they are exercisable in isolation over a plain `Box<Int>`.

```swift
func latest<Root: AnyObject, Value: Sendable>(
    _ slot: ReferenceWritableKeyPath<Root, Task<Value, Error>?>,
    on root: Root,
    debounce: Duration? = nil,
    _ work: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    root[keyPath: slot]?.cancel()
    let task = Task {
        if let debounce { try await Task.sleep(for: debounce) }
        return try await work()
    }
    root[keyPath: slot] = task
    let value: Value
    do {
        value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    } catch let urlError as URLError where urlError.code == .cancelled {
        throw CancellationError()                                   // URLSession surfaces cancel as URLError
    }
    guard root[keyPath: slot] == task else { throw CancellationError() }   // latest-wins at delivery
    return value
}

func cancel<Root: AnyObject, Value>(_ slot: ReferenceWritableKeyPath<Root, Task<Value, Error>?>, on root: Root) {
    root[keyPath: slot]?.cancel()
    root[keyPath: slot] = nil
}
```

The fetch moves to the call site — `try await latest(\.feed, on: tasks) { try await Dependencies.current.client.frontPage(0) }` — so the slot and the call both read at the point of use.

Latest-wins is enforced **at delivery**, not by cancellation alone. `Task.cancel()` only requests cooperative cancellation, so a fetch whose round-trip completes before the cancel is observed would otherwise hand its value to a superseded caller. The post-await `root[keyPath: slot] == task` check throws `CancellationError` for a superseded caller regardless of whether its work honoured the cancel, so callers commit unconditionally without their own staleness guard.

**`apply` is `async` and caller-following.** It commits the `Model` in place after the await and no longer returns a `Task`; `.refreshable` awaits `apply` directly. Each fetch arm performs its read-modify-write before the first `await`, so it stays atomic against actor reentrancy, and the post-fetch commit resumes back on the host actor.

**The feed shares one slot for its initial load and its load-more.** Both run through `latest(\.feed, on:)`, so a refresh cancels an in-flight load-more intrinsically — the explicit cross-slot `cancel(.feedMore)` ADR-0025 needed is gone. A `!feedInitialStatus.isLoading` guard makes a load-more yield to a refresh rather than cancel the reload it shares the slot with.

**Search is unified with the feed: one `search` slot, an apply-shaped arm.** The search reload is `applySearch(query:to:tasks:)`, shaped exactly like an `apply` fetch arm (`await load` over `latest(\.search, on:)`), and the search load-more (`apply`'s `.loadMore`) shares that same slot — so a new query cancels an in-flight load-more intrinsically, the mirror of feed. Search stays binding-driven: the field writes `model.searchQuery`, and a thin long-lived driver (`runSearch`) reads `searchQueryChanges` and *spawns* an `applySearch` per query change (spawning rather than awaiting, so the driver keeps reading the next keystroke while a reload is in flight). Each reload commits the `Model`, so it runs on the host actor via the injected `spawn` — `makeCore` takes a `spawn` parameter (the same isolation-carrying spawner ADR-0025 injected: static `@MainActor` in production, `_ = isolation` capture in tests), used for the driver and each reload it spawns. The awaited feed and search-load-more paths call `latest` directly and need no spawner.

**Order-safety rests on SE-0431, not a held handle.** The per-query tasks `runSearch` spawns enqueue their initial job in creation order on the host actor (SE-0431: same-priority tasks whose closures are isolated to the same executor begin executing in creation order), and each claims the `search` slot in its *synchronous head* — before its first real suspension (`await task.value` on the inner fetch). So they occupy the slot in query order, and the delivery guard lets only the last (newest) commit. This is the same ordering the `feed` slot already relies on; for search it is load-bearing. The invariant is unenforced by types — the slot must be claimed in the synchronous head, the spawned closure must stay host-actor-isolated, and priority must stay uniform (nothing `await`s an older reload's value) — and is noted in `applySearch`.

So the capability to start a `Task` on an isolation that may mutate the `Model` is retained, scoped to the one path that genuinely needs it, instead of mediating every fetch.

## Consequences

- `TaskRegistry`, `TaskID`, and the keyed cancel-and-replace store are removed. A flat `Tasks` of two `Task?` slots (`feed`, `search`) replaces them — one per list, each shared by that list's initial load / reload and its load-more — operated by the free `latest` / `cancel`.
- The cooperative-cancel race is closed in one place — `latest`'s delivery guard — rather than per call site. A load-more whose round-trip completes after being superseded no longer appends a stale page or desyncs the pagination cursor.
- `apply` no longer returns a `Task`. `.refreshable` holds its spinner by awaiting the fetch through `apply` itself.
- Cross-surface cancellation is intrinsic to each shared slot: a refresh cancels an in-flight feed load-more, and a new query cancels an in-flight search load-more, because both run through their list's one slot. No explicit cross-slot `cancel` remains (a `!initialStatus.isLoading` guard makes a load-more yield to a refresh / reload rather than cancel it).
- The injected spawner is used only for the search driver and the reloads it spawns — not for feed refresh, feed load-more, or search load-more, which call `latest` directly. The isolation-capture spelling is unchanged from ADR-0025, now confined to that one path.
- The registry is threaded as a `tasks: Tasks` parameter alongside `state: Model`, so the `Core` keeps **no** lock, actor, `@unchecked Sendable`, `nonisolated(unsafe)`, or underscored attribute — the slots are non-`Sendable` and region-confined, proven by the compiler. The alternatives below trade that for an ambient `@TaskLocal`; none was worth it.
- Tests no longer observe the registry (ADR-0022). They await `Model` transitions via `waitUntil`, or the awaited `apply`. `latest` / `cancel` carry their own unit tests over a `Box`, and a cancellation-ignoring `Hold` test helper reproduces the cooperative-cancel race the delivery guard prevents.
- The search reload has no bespoke staleness guard: it goes through the shared `search` slot, so a superseded reload throws via the delivery guard (authoritative — it fires even if the work completed, so it is robust to a same-string re-type, with no purity assumption). Combined with the SE-0431 occupation order, the newest query is the only committer.
- [ADR-0023](0023-ambient-debounce-clock-free-tests.md)'s ambient `searchDebounce` and [ADR-0020](0020-ambient-dependencies-struct.md)'s ambient `Dependencies` are unchanged: the reload passes `debounce:` to `latest`, and the fetch reads `Dependencies.current`.

## Alternatives considered

**A `Latest` / `Source` wrapper type for the slot.** An intermediate kept the slot behind a `callAsFunction` class (`Latest<Value>`), then a richer `Source<Input>` that also bound the fetch closure and the debounce. Rejected: a slot is just a `Task?` cell, and the wrapper added a `callAsFunction`, a stored closure, and a generic parameter on top of "a `Task?` field" without buying anything the field plus the two free functions do not. The policy is a handful of lines shared by four call sites — that earns a free function, not a type.

**Ambient `Tasks` via a `@TaskLocal` (eliding the parameter).** To drop the `tasks` parameter from `apply` / `runSearch` / `applySearch`, the registry could be installed as a task-local read through `Tasks.current`, the stateful sibling of `Dependencies.current`. A task-local value must be `Sendable` — it is inherited into every child task's region, which is the region-escape `Sendable` polices — and the registry is non-`Sendable` mutable state, so making it ambient forces exactly one opt-out the rest of the core avoids. Three were built and measured, each adding a trapping `current` accessor (the Point-Free "unimplemented dependency" trap) so a missing binding fails loudly rather than silently never superseding:

- *a cross-platform lock* (`OSAllocatedUnfairLock` on Apple, holding the iOS 17 floor; the standard-library `Mutex` elsewhere, where the iOS-18 gate does not apply) — a checked `Sendable`, but a lock that guards nothing the host actor does not already serialise, plus a wrapper type and `withLockUnchecked` (the key-path capture is not `Sendable`);
- *`@unchecked Sendable`* — a single annotation, safe by construction (the slots are touched only on the host actor; the in-flight fetch `Task` never reads them), direct synchronous access, zero runtime cost, but an asserted rather than compiler-checked conformance;
- *laundered `@isolated(any)` operations* (`@_inheritActorContext` carries a closure's formation isolation, legalising its non-`Sendable` capture under `@Sendable`) — checked and lock-free, but it needs an `isolated`-parameter formation context, so `makeCore` reverts from the injected `spawn` to an `isolated host` (undoing ADR-0025), the slot becomes a `Sendable` enum rather than a key path (it crosses into a possibly-hopping op), and the policy splits from the ambient entry. `@_inheritActorContext` is an underscored attribute already declined in [ADR-0019](0019-core-free-functions-uicore-split.md) and ADR-0021.

All rejected. Every ambient form pays a lock, an `@unchecked`, or an underscored attribute (the last also an architecture reversal) to delete a parameter that rides harmlessly beside the `Model` the same functions already thread. Threading the registry keeps it non-`Sendable` and region-confined with no opt-out at all, which is the property the whole core is built on.

**Keep a merge-stream search consumer with a `Sendable` reload.** An earlier form kept the reload `Sendable` by routing it through a second `AsyncStream`: the reload `Task` did only the fetch and yielded its page back as an event the consumer committed, with a forwarder `Task` bridging `searchQueryChanges` into the event stream. It avoided spawning a `Model`-mutating reload — but the host-actor spawner was retained anyway (to start the consumer), so the purity bought nothing and cost an event enum, a second stream, and a forwarder task. Rejected: once the spawner is already present, using it for the reload collapses the consumer to a plain cancel-and-replace loop.

**Per-arm staleness guards on each load-more commit.** Guard each commit with `query == state.searchQuery` (search) or a cursor check (feed) instead of fixing the slot. Rejected: the feed cursor check is insufficient — a refreshed page-0 snapshot carries the same page number as the one being appended onto — and the delivery guard fixes both load-more surfaces at the slot's own boundary, in one place.

**A synchronously-cancelled handle for the search reload (no SE-0431 reliance).** The reload could stay in the driver as a held `Task` cancelled synchronously in the loop (`reload?.cancel(); reload = spawn { … }`) plus a post-fetch `checkCancellation`, order-safe *without* depending on task start-order — the prior occupant is cancelled before the next is spawned, in stream order. Rejected for the unified form: it keeps search a bespoke consumer loop rather than an apply-shaped arm, and duplicates the cancel-and-replace the `search` slot already does. The cost of the chosen form is that search-keystroke correctness leans on SE-0431's ordering guarantee — but `feed` already leans on it, the guarantee is specified, and the win is one shape for both lists. Kept as the documented fallback if that reliance ever becomes untenable.

**Message-driven search.** Dispatch a `.search(query)` message per keystroke instead of binding `model.searchQuery`. Each `SendMessageAction.send` already spawns its own non-blocking `Task`, so search would join the awaited-`apply`-commits path and the host-actor spawner could be removed entirely. Rejected to keep search binding-driven: the text field binds `model.searchQuery` and the Android `BridgedSource` write-through is built for it. The spawner is retained for the one consumer instead.
