# ADR-0024: Carry isolation in the work value — `@Sendable @isolated(any)` via `inheritingIsolation`

## Status

Accepted (2026-06-13). Amends the revision of [ADR-0021](0021-spawn-owning-task-registry.md) (the bookkeeping-only registry) and overturns, with changed calculus, the `@_inheritActorContext` rejections recorded in [ADR-0019](0019-core-free-functions-uicore-split.md) and ADR-0021.

## Context

ADR-0021's revision established that on this toolchain a *suspending closure passed as a value* is not reliably pinned to the host actor after its first internal `await`, and retreated to `Task` literals written directly in isolated function bodies, with the registry reduced to bookkeeping. That shape is sound but spreads the spawn across call sites and couples correctness to literal placement.

The diagnosis behind the failure points at a sharper fix. The leaking work was typed `nonisolated(nonsending)`, which means *run on the caller's isolation* — the executor is supplied dynamically at each call, so when a calling chain lost its pin, the work went down with it. [SE-0431](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0431-isolated-any-functions.md)'s `@isolated(any)` inverts the ownership: the closure's isolation is captured *into the value* at formation, and `Task` "synchronously enqueue[s] the new task directly on the appropriate executor for the task function's dynamic isolation" — normative text, not inference. Work that owns its executor cannot be stranded by its caller.

Probes established the mechanics:

- An `@isolated(any)` literal bound to a local of non-`Sendable`, non-`sending` contextual type inherits the enclosing isolation — but the resulting non-`Sendable` value **cannot move**: region checking rejects it at every generic `sending` parameter and `sending` result (the "inherently `Sendable`" property SE-0431 describes for actor-isolated function values is not implemented for user-code plumbing).
- The value can move if it is `@Sendable` — and legalising non-`Sendable` captures under `@Sendable` is precisely what `@_inheritActorContext` does. An identity function with that attribute on its parameter is therefore the *minimal* toolkit for this design, not a convenience.
- Runtime-verified: the value carries instance actors (not just global actors), and the work — including every post-`await` segment, under cancel-and-replace churn — runs on the carried isolation regardless of where it is spawned from.

## Decision

**`inheritingIsolation(_:)`** is that identity function: it returns its operation as a `@Sendable @isolated(any)` value carrying the formation context's isolation. (The mechanism is "upgrade non-`Sendable` work to `Sendable` by inheriting the actor context"; the function is named for that, deliberately not for the laundering metaphor.)

**`TaskRegistry` spawns the work it tracks, with no isolation of its own.** `run(_:_:)` takes the carried-isolation value, cancels the prior occupant, and spawns with plain `Task(operation:)` — the universal spawner, since the executor rides in the value. No injected spawn closure, no boundary-built registries, no `assumeIsolated`, no `nonisolated(unsafe)`, and `makeCore` is self-contained again. The identity-guarded `vacate(_:ifStill:)` runs in the work's own tail (inside the carried isolation), with the handle threaded through a small box.

**Isolated parameters remain at the work-formation sites** — `makeCore` → `apply` → `applySearchQuery` → `load` — because inheritance must bind somewhere: in an isolated-parameter context the literal must strongly capture the parameter (`_ = isolation`, [SE-0420](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0420-inheritance-of-actor-isolation.md)). Forgetting that capture is a **compile error** whenever the operation touches non-`Sendable` state — which in this core is every operation — so the mistake cannot ship silently.

**Why the underscored attribute is now acceptable.** ADR-0019 and ADR-0021 rejected authoring against `@_inheritActorContext` when stable alternatives were equivalent — the attribute bought nothing. After the ADR-0021 revision, every stable alternative carries a material cost: the literal-placement discipline couples correctness to where code is written; the statically-injected-spawner variant needs per-boundary registry construction plus `assumeIsolated` and `nonisolated(unsafe)` rebinds on the test side. The attribute now buys the cleanest sound design, its misuse fails loudly at compile time, and the runtime contract it feeds (`@isolated(any)` enqueueing) is evolution-reviewed. The residual risk — underscored semantics changing without review — is bounded by two things: the dormant [closure isolation control pitch](https://forums.swift.org/t/closure-isolation-control/70378)'s `@inheritsIsolation` is the stable spelling this helper dissolves into if it ships, and the failure mode (silent off-actor work) is exactly what the endurance gate below detects.

## Consequences

- One underscored attribute, authored once, in one file, with the rationale and the dissolution path documented on the declaration.
- The registry is the single spawn point again, and the whole chain rests on carried isolation rather than caller pins: the class of bug ADR-0021's revision documented is structurally absent, not avoided by discipline.
- The verification bar set by that investigation stands: ThreadSanitizer cannot gate this (it reports artifactual races on custom-executor actors, including on untouched baselines); the gate is repeated plain full-suite runs — 15/15 clean on adoption, in the configuration that failed within ~3 under the nonsending design. **Re-run that gate on toolchain updates**, since both the attribute's semantics and the original failure were toolchain-sensitive.
- `Task(operation:)` enqueues synchronously on the carried isolation (SE-0431), so registration-before-body and spawn ordering hold as before; `Task.immediate` remains unusable for the registry.

## Alternatives considered

**The literal-placement shape (ADR-0021 revision, superseded by this ADR).** Sound on stable features alone; kept as the documented fallback if the attribute's semantics ever shift. Its cost is the discipline itself: every spawn site must keep post-`await` state access textually inside an isolation-capturing `Task` literal in an isolated function body, and the registry cannot own spawning.

**Statically-injected spawners.** Build the registry where isolation is known statically — `Task { @MainActor in … }` in `makeAppCore`, a `TestActor` method owning the literal in tests — and inject it into `makeCore`. Also sound (15/15), and the only variant that removes isolated parameters entirely. Rejected: the composition root splits per consumer, and the test wiring needs `assumeIsolated` plus `nonisolated(unsafe)` rebinds — heavier exotic surface than one attribute, in exchange for parameter elision the formation sites don't mind carrying.

**Non-`Sendable` `@isolated(any)` plumbing (attribute-free).** Fails region checking at every `sending` boundary; there is no attribute-free spelling of carried-isolation work values today.
