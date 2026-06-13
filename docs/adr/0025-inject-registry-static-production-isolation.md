# ADR-0025: Inject the `TaskRegistry` at the composition boundary — static production isolation, dynamic test isolation

## Status

Accepted (2026-06-13). Amends [ADR-0021](0021-spawn-owning-task-registry.md) and the Swift 6.4 form of [ADR-0024](0024-isolation-carried-work-values.md): the task spawner moves out of `makeCore` into its two callers.

## Context

On Swift 6.4 (after the [ADR-0024](0024-isolation-carried-work-values.md) update shed the 6.3 workaround stack), `makeCore` took `isolation: isolated any Actor = #isolation` and built the registry's spawner internally as `Task { _ = isolation; await work() }`. The `_ = isolation` capture is what SE-0420 requires to inherit an *instance* actor's isolation. But it is applied uniformly to both consumers, and production's isolation is not an instance — it is `MainActor`, a **global** actor whose isolation is static and inherited by a closure unconditionally. So production was paying the dynamic-isolation-capture spelling for an isolation that is statically known.

[ADR-0024](0024-isolation-carried-work-values.md) listed "statically-injected spawners" as a *rejected* alternative, but only in its static-**both** form: production `Task { @MainActor in … }` and tests reaching a `TestActor` method through `assumeIsolated` + `nonisolated(unsafe)` rebinds. That test-side machinery was the reason for rejection. A static-**production**, dynamic-**test** split was not separately evaluated.

## Decision

`makeCore` is **nonisolated** and takes the registry as a parameter:

```swift
func makeCore(model: Model = Model(), tasks: TaskRegistry<TaskID>) -> Core
```

Each caller builds the registry with a spawner bound to *its* isolation:

- **Production** ([`makeAppCore`](#), `@MainActor`): `TaskRegistry { work in Task { @MainActor in await work() } }`. The spawned `Task` inherits `MainActor` from the explicit `@MainActor in` annotation — **no `#isolation` capture**, idiomatic global-actor code.
- **Tests** (`withCore`, isolated to a per-test `TestActor` instance): `TaskRegistry { work in Task { _ = isolation; await work() } }` — the `_ = isolation` capture SE-0420 requires for a dynamic *instance* actor.

So the `_ = isolation` ceremony lives only in test code, where the isolation genuinely is a dynamic instance; production reads as a plain global-actor `Task`. `makeCore` runs on (and confines its non-`Sendable` state to) whatever actor calls it; being nonisolated, it loses the `isolated` parameter entirely.

This compiles with **no unsafe opt-outs**. The static-both form ADR-0024 rejected needed `assumeIsolated` + `nonisolated(unsafe)` because it threaded the non-`Sendable` work into a `TestActor` *method*; the static-production/dynamic-test split here never does that — the test spawner is a plain `Task { _ = isolation; … }` literal, and the production `Task { @MainActor in … }` is a global-actor closure (inherently `Sendable` per SE-0431), so passing the work into it is accepted. Verified 15/15 on the endurance gate under Swift 6.4.

## Consequences

- **Production carries no isolation-capture trick.** `makeAppCore` is plain `Task { @MainActor in … }`; the dynamic-capture spelling is confined to the test harness, where it is warranted. `makeCore`'s signature drops the `isolated` parameter.
- **`makeCore` is no longer fully self-contained.** The spawner is defined at the two call sites rather than once inside `makeCore`, and each caller must construct and inject the registry. This is the cost traded for capture-free production: the previous form had one spawner definition and a uniform `#isolation`, at the price of production wearing the instance-capture spelling.
- The bridged surface is unchanged — `makeAppCore`'s signature is the same; only its body and `makeCore`'s signature change. App call sites (`SendMessageAction(core)`) are unaffected.
- The conceptual model is sharper: dynamic-instance-isolation capture is a *test* concern (instance actors per test), and production's static global-actor isolation is expressed as such. For a forward-looking, architecture-proving project, that separation is the point.

## Alternatives considered

**`makeCore` owns the spawner (the prior form).** One spawner definition, uniform `#isolation` for both consumers, fully self-contained `makeCore`. Rejected for production wearing the instance-capture spelling (`_ = isolation`) for an isolation that is statically `MainActor` — the spelling reads as "dynamic instance capture" where none is needed. Kept as the documented fallback: it is sound on 6.4 and a single edit away.

**Statically-injected spawners, static-both (ADR-0024's rejected form).** Tests also go static via a `TestActor` method owning the `Task` literal, reached through `assumeIsolated` + `nonisolated(unsafe)`. Rejected there and here: the test-side unsafe machinery buys nothing that the dynamic `_ = isolation` capture doesn't, and it is heavier surface. The split adopted here takes the static benefit only where it is free (global-actor production).
