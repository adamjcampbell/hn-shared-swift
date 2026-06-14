# ADR-0022: Observe the `TaskRegistry` as a test synchronisation signal; retire `settle`

## Status

Superseded by [ADR-0026](0026-replace-registry-with-latest-slot.md) (2026-06-14): the `TaskRegistry` it observed is gone, so tests await `Model` transitions via `waitUntil` instead. The `settle`-retirement it introduced stands.

Was Accepted (2026-06-12). Builds on [ADR-0021](0021-spawn-owning-task-registry.md).

## Context

The test suite's default synchronisation is `waitUntil`: re-arm `withObservationTracking` on whatever the condition reads and suspend until the real transition happens. That worked only for transitions visible on the `@Observable` `Model`. Steps that leave `Model` unchanged — the listener processing a keystroke whose `isLoading` is already true, a cancel-and-replace flowing through parked sleeps — had no signal, so the suite carried `settle`: drain the `TestActor`'s queue twice, with an explanation of why two is the minimal deterministic count ("a `searchQuery` write resumes the listener as a new job behind the one already running"). A drain count is scheduler topology encoded as a constant; it holds until the job graph changes shape, and nothing fails loudly when it does.

After ADR-0021 every one of those invisible steps does leave a trace — in the `TaskRegistry`. A processed keystroke cancels and replaces the `.search` slot; a spawned fetch registers; a finished fetch self-removes. The registry was just not observable, and not reachable from tests.

## Decision

**`TaskRegistry` is `@Observable`.** Its `entries` dictionary is the tracked state; a read-only `subscript(id:) -> Task<Void, Never>?` is the observable read. Mutation stays behind `replace` / `vacate` / `cancel` / `cancelAll` (the post-revision ADR-0021 surface), so the registration and self-removal bookkeeping cannot be bypassed.

**`Core` exposes the registry as `internal // SKIP @nobridge let tasks`** — the same visibility treatment as `sendMessage` and `cancelAll`: tests in-module reach it, app code and JNI never see it, and its non-`Sendability` confines any caller to the host region.

**Tests wait on registry transitions with the existing `waitUntil`.** No new helper: the condition closure reads the subscript, observation tracking covers it exactly as it covers `Model` fields. `Task`'s `Equatable` conformance turns membership into three watchable transitions:

- registered — `waitUntil { core.tasks[.search] != nil }`
- replaced — `let before = core.tasks[.search]; …; waitUntil { core.tasks[.search] != before }`
- removed — `waitUntil { core.tasks[.search] == nil }` (self-removal on completion)

**`settle` is deleted.** Its two call sites converted to registry waits, which also strengthened them: the rapid-keystroke test now asserts each cancel-and-replace by task identity instead of draining and hoping. The remaining single `runPending()` calls are a different kind of signal — execution progress (a fetch task parking on its `clock.sleep` so `advance` lands on a sleeper), which membership observation cannot see; each carries a comment naming the step it drains.

## Consequences

- One synchronisation idiom. Every wait in the suite is either a `waitUntil` on an observable condition (`Model` or registry) or a single named `runPending` for park-at-sleep; the "drain twice" constant and its job-ordering lore are gone.
- Cancel-and-replace is now assertable, not inferred: identity inequality across a keystroke is direct evidence the listener processed it, even when no `Model` field moves.
- Production pays the observation registrar on registry mutations — a handful of writes per user action across five ids, beneath measurement. Production never reads the registry; nothing observes it outside tests. (If a UI ever wants an in-flight indicator keyed by task id, the signal now exists, but that is not a goal of this decision.)
- The registry observes *membership*, not *progress*. The irreducible `runPending`s mark exactly the steps where the awaited fact is "the task has reached its sleep". If those ever multiply, the next signal to make observable is the clock — a spy `Clock` that records sleeper registration would make "parked" a `waitUntil`-able condition too. Not built; recorded as the known extension point.
- `Core` carries one more non-bridged member; the `// SKIP @nobridge` annotation is load-bearing for the Android build, as ADR-0019 established for `sendMessage` / `cancelAll`.

## Alternatives considered

**An `AsyncStream` of spawn emissions instead of `@Observable`** (investigated in depth 2026-06-12, probe-verified). The registry yields `(id, task)` through a lazily-created continuation — `spawnsContinuation?.yield(…)` — so production, which never asks for the stream, pays one nil check per `run` and no observation registrar. A receiver gets each spawned task delivered directly, in order, exactly once: a real spawn *log*, which is the one thing observation cannot reconstruct (a state read can miss intermediate occupants; an emission cannot be missed). The probe confirmed the shape compiles and behaves on stable features.

Rejected nonetheless, on fit rather than mechanics:

- *State questions outnumber event questions.* The registry's own tests assert "the slot is vacant after completion", "the joined task **is** the in-flight one", "the survivor is not cancelled" — present-tense reads a log cannot answer without the consumer replaying it into state, which is the subscript reinvented.
- *One idiom.* `waitUntil` over an observable read covers `Model` and registry with the same mechanism and the same FIFO-resume reasoning; a stream reintroduces a second synchronisation idiom (iterator lifecycle, created-before-trigger or buffered-with-history, one consumer per stream) for one test's benefit — after ADR-0023, only the keystroke-collapse test waits on registry transitions at all.
- *The first emission is the listener.* `makeCore` registers `.searchListener` through the same path as every fetch, so every consumer starts by filtering noise, or the registry grows an emission policy.
- *Conditions self-heal; consumption doesn't.* The transient-nil subtlety found during the ADR-0023 conversion was fixed by strengthening a condition (`!= nil && != before`) — spurious wake-ups re-arm for free. A log consumer confronted with an unexpected emission needs protocol, not a stronger predicate.

The criteria that would flip this: tests start asserting spawn order or counts across ids (the log is then the honest signal), or production grows a consumer for in-flight events. The lazy-continuation pattern is recorded here for that day.

**Exposing the `entries` dictionary directly.** Smaller diff, but hands tests (and future in-module code) a mutable path around `run`'s cancel/replace/self-removal bookkeeping. The get-only subscript keeps the write surface where the invariants live.

**A test-only observation wrapper instead of `@Observable` on the type.** The macro cannot be retrofitted from a test target — the registrar has to live in the type's storage — so this would mean hand-rolled change hooks (a delegate closure the test installs), which is the `AsyncStream` alternative with fewer affordances.

**Keeping `settle`.** Status quo. Rejected for the reason in Context: a drain count encodes the scheduler's current job topology; the registry transition is the fact the test actually means.
