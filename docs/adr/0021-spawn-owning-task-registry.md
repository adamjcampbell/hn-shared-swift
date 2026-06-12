# ADR-0021: Bind isolation once into a spawn-owning `TaskRegistry`; drop the threaded `isolated` parameters

## Status

Accepted (2026-06-12). Amends [ADR-0019](0019-core-free-functions-uicore-split.md): replaces the isolation-threaded free-function composition with a registry that owns task creation. ADR-0019's other decisions — one isolation-generic `Core` handle, the `@MainActor` `SendMessageAction` boundary, free functions as the sole `Model` writers — stand unchanged.

## Context

[ADR-0019](0019-core-free-functions-uicore-split.md) composes the core from free functions, each threading `isolation: isolated any Actor = #isolation` (SE-0420). The threading exists for exactly one reason: spawning an unstructured `Task` whose body captures the non-`Sendable` `Model`. A bare `Task { }` in that position infers `@concurrent` and fails region checking; referencing an isolated parameter inside the closure (`_ = isolation`) makes it inherit that isolation and compile. Because `apply`, `applySearchQuery`, and `loadTask` all spawned tasks (and `fetch` wanted its post-sleep continuation pinned), four signatures carried the parameter, and the `sendMessage` closure carried a `_ = isolation` line whose only job was to make `#isolation` inside `apply` resolve to the host actor rather than `nil`.

The registry added its own constraints. As a struct threaded `inout`, an escaping closure could not capture it (forcing the listener inline in `makeCore`), and the `inout` access window meant `apply` had to stay synchronous and return its spawned `Task` so the caller could `await` outside the access — an exclusivity trap on top of the actor-reentrancy discipline.

Three compiler facts shape the alternatives (verified by probe on the package's settings — Swift 6.1 tools, language mode v6, `NonisolatedNonsendingByDefault`):

1. Region checking admits passing an actor-region closure to a `sending` parameter of a callee whose `isolated` parameter is bound to that same actor — the value never leaves the isolation domain (SE-0430's rules as implemented; no normative sentence states the closure case directly, hence probe-verified). A `Task.isolated(isolation:operation:)` helper therefore needs **no underscored attribute**: the helper's body does the `_ = isolation` capture once, and call sites pass region-confined closures freely. Runtime-asserted to run on the host actor.
2. A `nonisolated(nonsending)` async function (SE-0461, the package default) runs on its caller's actor, but **cannot spawn** an actor-bound `Task` from its implicit isolation: a `Task { }` capturing a non-`Sendable` parameter is rejected (`#SendingClosureRisksDataRace`). Making `apply` async to reach `#isolation` is a dead end — and would also dissolve the synchronous read-modify-write guarantee.
3. The `@_inheritActorContext`-based `launder` shape (returning a `@Sendable @isolated(any)` closure that inherits the formation context) works and carries the right dynamic isolation, but is inseparable from the underscored attribute: removing it makes the `@Sendable` capture of non-`Sendable` state an error. This is the surface ADR-0019 already rejected, now with the dependency demonstrated rather than presumed.

So isolation must be bound where an isolated parameter is *statically* in scope — and `makeCore` is the only place that needs to be.

## Decision

**`TaskRegistry` becomes a non-`Sendable` `final class` that owns the ability to create tasks.** `makeCore` constructs it with a spawn closure that binds the isolated parameter once:

```swift
let tasks = TaskRegistry<TaskID> { work in
    Task {
        _ = isolation
        await work()
    }
}
```

`isolation` now appears in one signature (`makeCore`) and one closure (the spawn). That one `_ = isolation` rests on evolution-reviewed text, not on `@_inheritActorContext`: [SE-0420](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0420-inheritance-of-actor-isolation.md) specifies that a `Task` closure inherits an isolated parameter's isolation when it *strongly captures* that parameter, and `makeCore`'s parameter is non-optional, so the capture sits within the proposal's letter (optional isolated parameters are the gray zone — SE-0420 asks for a non-optional binding). Same-isolation `Task` creation enqueues synchronously on the host executor (SE-0431), so spawn order — and with it the fire-and-forget ordering `SendMessageAction.send` documents — is unchanged. Every other function in the core is synchronous (runs where called) or `nonisolated(nonsending)` async (runs on its caller's actor); all callers trace back to the region `makeCore` was formed on, because every entry path closes over the non-`Sendable` registry or `Model`. `apply(_:to:commands:tasks:)`, `applySearchQuery(_:to:tasks:)`, and `fetch(debounce:body:)` lose their `isolated` parameters; the `sendMessage` closure loses its `_ = isolation` line; `loadTask` becomes `load(_:into:status:tasks:…)`, registering through the registry instead of returning a task for the caller to file.

**The class dissolves the `inout` constraints.** The listener can be spawned through the registry itself (`tasks.run(.searchListener) { … }`); nothing forces it inline any more, and there is no exclusivity window. `apply` stays synchronous and still returns the in-flight `Task` — but the remaining reason is the real one (the host actor serialises execution steps, not whole handlers; a suspension inside a read-modify-write would lose updates to reentrancy), no longer an `inout` access rule layered on top.

**The registry gains collision strategies and self-removal.** `run(_:strategy:work:)` takes a `Strategy`:

- `.cancelAndReplace` (default) — cancel the in-flight task for the id and start the new work. Latest-wins; the debounced search and pull-to-refresh semantics, unchanged from the subscript-assignment behaviour it replaces.
- `.joinInFlight` — return the existing in-flight task untouched and drop the new work, so the caller awaits (resubscribes to) the run already happening.

A finished task removes its own entry, guarded by an identity check (`Task` is `Hashable`) so a replaced task finishing late cannot vacate the slot its replacement now owns — the same compare-before-remove guard VergeGroup's [swift-concurrency-task-manager](https://github.com/VergeGroup/swift-concurrency-task-manager) uses, where the strategies are called `.dropCurrent` / `.waitInCurrent`, and the moral equivalent of the identity-based removal in [TCA's effect cancellation](https://github.com/pointfreeco/swift-composable-architecture/blob/main/Sources/ComposableArchitecture/Effects/Cancellation.swift). Self-removal is what keeps `.joinInFlight` honest: an id with an entry is an id with live work, never a completed task a joiner would await into a no-op. Joiners receive the task and use plain `.value`; a joiner's own cancellation neither cancels nor detaches from the shared work (per-awaiter detachment is the Nuke-style refcounting escalation, not needed at this scale). The spawn closure must enqueue rather than run inline (`Task { }`, never `Task.immediate`), since the guard registers the task before its body may start.

All production call sites keep `.cancelAndReplace` semantics today; `.joinInFlight` is the recorded option for pull-to-refresh joining an in-flight refresh or load-more deduplication, should either be wanted. Enqueue-behind (per-key FIFO) and drop-new were considered and folded away: drop-new is `.joinInFlight` with the returned task discarded, and enqueue-behind has no use case in a latest-wins UI core.

## Consequences

- One isolated parameter in the core, in `makeCore`, where composition happens; zero in the message handlers. The `_ = isolation` idiom survives in exactly one place, with the registry's doc comment explaining it.
- The send closure no longer carries a line whose absence would change `#isolation` resolution three calls away — the failure mode ADR-0019 had to document ("a closure that dropped this would pass `nil`") is gone structurally.
- `apply` is testable without an actor in scope: it takes a registry value, so a recording spy (or a registry with an inline-asserting spawn) can observe which ids are scheduled. Not exploited yet; the suite still tests through `Core`.
- The registry is a reference type whose confinement now rests on non-`Sendability` alone, the same property that already confined `Model` and the send closure. The struct's value semantics were never load-bearing — the one instance lived in a captured `var` box precisely so every closure shared it.
- The `Cancellable` erasure protocol is gone: the registry spawns everything it stores, so storage is concretely `[ID: Task<Void, Never>]`, which is also what lets `.joinInFlight` hand the task back.
- Behavioural deltas from the subscript era, both invisible to the `Core` surface: entries self-remove on completion (previously a finished task lingered until overwritten — five fixed ids made that a bounded, harmless leak), and cancel-without-replacement reads `tasks.cancel(.feedMore)` instead of `tasks[.feedMore] = nil`.
- `Task.isolated(isolation:operation:)` is *not* added: with the registry owning spawn there is exactly one spawn site, and a helper for one call site is indirection without compression. The probe result stands recorded here: the helper needs only stable features (SE-0420 + SE-0430), so if spawn sites multiply it is the next move — not `@_inheritActorContext`.

## Alternatives considered

**Status quo (isolation-threaded free functions).** Works, shipped, and every guarantee here was already true there. Rejected on accounting: four threaded parameters, a load-bearing `_ = isolation` in the send closure, the inlined-listener constraint, and the await-outside-`inout` rule are all costs paid to re-derive, at every call site, a fact established once at composition time — which actor owns the region.

**Async `apply` reading `#isolation`.** Would erase the parameter without injecting anything: under `NonisolatedNonsendingByDefault`, `#isolation` inside async `apply` is the caller's actor. Rejected twice over: the compiler rejects spawning from it (probe fact 2 — the implicit isolation is not capturable by a `Task` closure), and an async `apply` trades the synchronous-handler invariant for "async but must never actually suspend", which no type enforces.

**`@_inheritActorContext` surfaces (`launder`, a `Sendable` send closure, an attribute-bearing `Task.isolated`).** The laundered closure carries the correct dynamic isolation and would let capabilities cross regions. Rejected for the reason recorded in ADR-0019, now compiler-demonstrated (probe fact 3): the shape does not exist without the underscored attribute, whose semantics the Swift repository documents as unstable and strongly discouraged outside the standard library. The would-be stabilisation — the [closure isolation control pitch](https://forums.swift.org/t/closure-isolation-control/70378)'s `@inheritsIsolation` — has been dormant since March 2024 and would *change* the semantics (unconditional capture) if revived. Consuming the attribute transitively through `Task.init` remains fine; authoring against it does not. Notably, the probe showed the attribute is *unnecessary* for the isolated-parameter helper shape — where it appeared to help, stable `sending` rules were doing the work.

**A `Sendable` registry over a lock (`Mutex<[ID: Task]>`).** The shape from the exploration sample that prompted this ADR. Rejected: `Synchronization.Mutex` needs an iOS 18 floor (the package floor is 17), and the lock buys reach the design forbids anyway — every legitimate caller is already in one region, so the lock would serialise accesses that non-`Sendability` proves can never contend, while silently licensing new callers from foreign regions.

**Deferred-spawn collector (`apply` appends `(id, work)` pairs; the factory spawns after it returns).** Also from the sample. Makes `apply` inspectable as pure data-out and moves task creation fully outside the handler. Rejected as the default because cancellation breaks the symmetry: `.refresh` cancels `.feedMore` mid-handler, so either cancels become collected instructions too (an interpreter grows where a method call sufficed) or the registry reaches `apply` anyway and the collector is a second channel beside it. The registry-as-parameter form keeps one channel and stays a plain call.
