# ADR-0023: Ambient `searchDebounce`; control time by amount, not by clock

## Status

Accepted (2026-06-12). Builds on [ADR-0020](0020-ambient-dependencies-struct.md) and [ADR-0022](0022-observable-task-registry-test-signal.md).

## Context

The core's only time-dependent behaviour is the search debounce: one `clock.sleep` between a `searchQuery` write and the fetch. To make that deterministic, `Dependencies` carried `clock: any Clock<Duration>`, the test target depended on `pointfreeco/swift-clocks`, and the suite drove a `TestClock` through a choreography: drain the actor's queue so the fetch parks on its sleep (`runPending`), `advance(by:)` past the debounce, drain again so the resumed fetch lands. Mocks parked mid-call the same way (`clock.sleep(for: .seconds(Int.max))` on a never-advanced clock). The drains encode scheduler topology — the same class of knowledge [ADR-0022](0022-observable-task-registry-test-signal.md) removed with `settle`.

The observation behind this ADR: a fake clock simulates *the passage of time*, but every debounce test actually needs only one of two *amounts* — "no window" (the fetch should run now) or "an open window" (the fetch must still be pending). Both are expressible as values of the debounce itself.

## Decision

**`searchDebounce` is a `Dependencies` field** (`Duration`, default 250 ms), read at the call site in `applySearchQuery` per [ADR-0020](0020-ambient-dependencies-struct.md) — a fourth field on the existing struct, not a second `@TaskLocal`. The `Core.searchDebounce` static and the `Dependencies.clock` field are gone; `fetch` sleeps on the real clock (`Task.sleep(for:)`).

**Tests pick the amount per scenario.** `withCore(debounce:)` defaults to `.zero`: the fetch runs straight through its sleep, so driving a search to commit is one wait on the terminal transition (`waitUntil { searchLoaded != nil }`, or awaiting the registry's task). Window-behaviour tests pass `debounceNeverElapses` (10⁶ seconds): real time never crosses it, so "inside the debounce window" is a stable state to assert against — loading is live while nothing has reached the client, a backspace cancels a fetch that is still parked, three keystrokes cancel-and-replace without a single client call. The parked sleeps release through cancellation on fixture exit, never by elapsing, so no wall-clock time is spent.

**Mocks park on a `Gate`, not a clock.** `Gate` is a small test rendezvous: the mock `await`s `arrive()` — signalling the test and parking — and the test `await`s `arrival()` to know the fetch is deterministically *inside* the client call before triggering whatever should interrupt it. The park releases on cancellation (or an explicit `open()`). This replaces the parked-`TestClock`-sleep idiom and is also what removed the last `runPending`s: "the fetch reached its sleep" needed a queue drain because parking is invisible, but "the fetch reached the client" is an event the mock itself can signal.

**swift-clocks is dropped**, along with `TestActor.runPending()` (no callers remain) and the `settle`-era drain machinery in full. Every synchronisation in the suite is now an observable condition (`waitUntil` over `Model` or registry), an await on completed work (`task.value`, `sendMessage`, `iterator.next`), or a `Gate` rendezvous.

## Consequences

- One spec is knowingly given up: "the fetch fires only after *exactly* the configured debounce" — pure elapsed-time behaviour is untestable without a controllable clock. The behavioural specs it guarded survive split across the two amounts: cancel-and-replace inside the window, no premature client calls, loading-before-results, and the surviving query committing are all still asserted.
- Zero third-party test dependencies. The `any Clock<Duration>` erasure, the `ImmediateClock` default, and the `TestClock`-vs-`ImmediateClock` choice per test are gone; `Dependencies` shrinks back to data the core actually reads.
- Debounce tests state their scenario in the fixture signature (`debounce: .zero` vs `debounce: debounceNeverElapses`) instead of in clock choreography spread through the body.
- The suite no longer owns any code that models time. `swift-clocks`' careful sleep-registration/advance semantics were load-bearing under the old design; nothing replaces them because nothing needs them.
- A subtlety the conversion surfaced, now documented on the registry waits: a slot-identity condition like `tasks[.search] != before` must also require `!= nil`, because a cancelled fetch unparks and self-removes on its own schedule, so the slot can be transiently empty when the test's re-check runs. "A different task is registered" is the honest condition; the spurious-wake re-arm in `waitUntil` handles the rest.

## Alternatives considered

**Keep `TestClock` only for the window tests.** Preserves the exact-elapsed-time spec. Rejected: it keeps the package dependency, the `clock` field, and two synchronisation idioms alive for one assertion of a UX tuning constant — and the drains it requires are the topology-encoding the last two ADRs removed.

**Hand-rolled minimal `TestClock`.** Drops the dependency, keeps determinism. Rejected: sleep registration, advance ordering, and cancellation are exactly the subtle concurrency code worth not owning; swift-clocks exists because getting them right is hard.

**Minimal real debounce (a few milliseconds) instead of `.zero`.** Rejected outright: it turns the collapse and window tests into wall-clock races — the flakiness the `TestClock` was originally adopted to kill.

**A separate `@TaskLocal` for the debounce.** Rejected for the reason recorded in [ADR-0020](0020-ambient-dependencies-struct.md): fixed, package-wide injectables live as fields on the one `Dependencies` struct.
