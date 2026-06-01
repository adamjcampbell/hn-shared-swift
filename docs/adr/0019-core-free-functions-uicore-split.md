# ADR-0019: Compose the core from isolation-threaded free functions; inner `Core` / outer `@MainActor` `UICore`

## Status

Accepted (2026-06-01). Supersedes [ADR-0015](0015-engine-borrows-host-executor.md) and [ADR-0016](0016-engine-actor-flat-model.md).

## Context

[ADR-0015](0015-engine-borrows-host-executor.md) made `Engine` a `final actor` that borrowed its executor from an `isolation: any Actor` initializer parameter (SE-0392): production passed `MainActor.shared` so calls were virtual hops, tests passed a `TestActor` for per-test parallelism. [ADR-0016](0016-engine-actor-flat-model.md) made that actor the sole writer of a flat `@Observable` `Model`.

The actor bought one thing: a single isolation region that serialised every `Model` and task-registry write and satisfied region isolation (SE-0414) for the non-`Sendable` `Model`. It cost an `unownedExecutor` property, a `nonisolated(unsafe)` rebind to lift `Model` out of the region into the `@MainActor` handle, and a layer of indirection between the factory and the code that actually mutates state.

An experiment showed the region can be established without an actor type. Threading `isolation: isolated any Actor = #isolation` through plain functions gives every `Task { … }` they spawn the same inherited isolation (SE-0420 / `@_inheritActorContext`), so the writes stay serialised to whatever actor the caller is on. The composition then happens directly in the factory rather than inside an actor's methods.

Two pressures still have to be reconciled, the same two [ADR-0015](0015-engine-borrows-host-executor.md) named: production wants the bridged surface pinned to `MainActor` ([ADR-0014](0014-mainactor-both-platforms.md)); tests want their own executor so the suite parallelises. The free-function form resolves this by packaging at two layers instead of by borrowing an executor.

## Decision

**Inner layer (`internal`, isolation-generic).** A `Core` struct bundles the `Model`, the `AsyncStream<Command>`, an `@isolated(any) (Message) async -> Void` send closure, and a `cancelAll` hook. `makeCore(model:client:clock:isolation: isolated any Actor = #isolation)` builds the command stream and a local `var tasks` registry, spawns the search listener inline, and returns the handle. The message handling is free functions — `apply(_:to:commands:tasks:client:clock:isolation:)`, `applySearchQuery(...)`, and `fetch(...)` — each threading `#isolation`.

Three details make this work:

- **`apply` is synchronous and returns the in-flight `Task`.** It assigns into `tasks` and returns; the send closure awaits `…?.value` *outside* the `inout tasks` access. Holding an `inout` access across the `await` would keep the captured `tasks` box exclusively accessed while the listener, on the same actor, also touches it, which traps. A synchronous `apply` cannot span a suspension, so the access is always bounded.
- **The listener is inlined in `makeCore`, not extracted into a `bind(tasks: inout …)` function.** An escaping closure cannot capture an `inout` parameter, so a listener `Task` that mutates `tasks` has to close over the *local* `var`. The listener, the send closure, and `cancelAll` all capture that one box; every one of them runs in `isolation`'s region, so the non-`Sendable` captures stay serialised.
- **The send closure is `@isolated(any)`.** It carries the host actor it was formed on, so every `await sendMessage(_:)` hops there before touching state. Concurrent callers — a UI fire-and-forget plus a `.refreshable`, or two tasks in a test — therefore serialise on one actor without the caller having to be isolated to it. A plain `(Message) async -> Void` type would let the compiler accept off-actor calls that race at runtime.

**Outer layer (`public`, bridged).** `UICore` is a `@MainActor struct` carrying the `Model`, the command stream, and a `SendMessageAction`; `makeUICore()` is `@MainActor`. It calls `makeCore()` (so `#isolation` resolves to `MainActor.shared`) and wraps the inner send closure in a `SendMessageAction` whose `Equatable` identity is the `Model`'s `ObjectIdentifier`, so SwiftUI's environment diff treats the capability as stable. This is the only surface that crosses JNI (`// SKIP @bridgeMembers` / `// SKIP @bridge`); the `@MainActor` boundary from [ADR-0014](0014-mainactor-both-platforms.md) is unchanged.

**Tests.** A `withCore` fixture is isolated to a per-test `TestActor` and calls `makeCore()` so `#isolation` binds there. There is no `Engine`, no `unownedExecutor`, no `nonisolated(unsafe)` rebind. Each test gets its own actor and queue, so the suite still parallelises across instances.

**Carried forward from [ADR-0016](0016-engine-actor-flat-model.md).** `Model` stays a flat `@Observable final class` with one field per axis; new state lands as a new field plus one arm on the `apply` switch. The `apply` free functions are the sole writers — the discipline that was "`Engine` is the only writer" now reads "only `apply` mutates `Model`". No mutators on `Model`.

## Consequences

- No actor type, no borrowed executor, no `nonisolated(unsafe)` rebind anywhere in the core target. Isolation is threaded by the compiler through `#isolation` and packaged at the `@MainActor` boundary in `makeUICore`.
- `@isolated(any)` on the inner send closure is load-bearing: it is what serialises concurrent callers. The previous actor gave this for free through its mailbox; the free-function form has to state it on the closure type.
- The `withCore` body runs as one isolated scope, so the `run { isolated engine in … }` batching helper from the actor era is gone — reads and `sendMessage` calls in a test body already share a consistent snapshot between suspension points. A `settle` helper drains the `TestActor` twice where a `model.searchQuery` write must be observed: `AsyncStream` schedules the listener's resume as a new job behind the one already running, so a single drain returns before the listener runs. Two is the minimal deterministic count on a serial queue — job ordering, not a load-dependent race.
- The cost of dropping the actor: the inner `Core.sendMessage` type no longer advertises its isolation the way an `actor` method signature did, so it reads as callable from anywhere. `@isolated(any)` keeps that safe at runtime, and production only ever calls it through the `@MainActor` wrapper, but the type is less self-documenting than the actor was.
- One composition root. `makeCore` is where the state, the stream, the registry, the listener, and the send capability are wired together, top to bottom, instead of split across an `init`, a `bind()`, and a set of actor methods.
