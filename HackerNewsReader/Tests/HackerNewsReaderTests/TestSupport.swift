import Clocks
import Foundation
import Observation
import Testing
@testable import HackerNewsReader
import HackerNews

/// Per-test ``Core`` fixture. Isolated to a fresh ``TestActor`` so
/// `makeCore` (and the whole `body`) run on it: `#isolation` binds
/// there, and every model / registry write stays serialised onto that
/// actor's queue. Cancels the listener on exit so the `Task → Model`
/// references release before the next test starts.
///
/// The body runs isolated to the `TestActor`, so reads and
/// `core.sendMessage(_:)` calls share a consistent snapshot between
/// suspension points — no separate `run { … }` batching is needed.
///
/// Default clock is `ImmediateClock`: the only `clock.sleep` in
/// production is the search debounce, and tests that don't validate
/// timing run faster with that sleep elided. Override with
/// `clock: TestClock()` when the test asserts on debounce timing, and
/// pass the same clock to ``commitSearch(_:core:clock:isolation:)``.
///
/// - Note: `client` / `clock` / `now` are bound into ``Dependencies`` and
///   `makeCore` runs *inside* the `withValue`, so the listener `Task` it
///   spawns — and every fetch the body triggers — inherits these deps.
///   (The clock is ambient for the core; the test still holds its own
///   `TestClock` reference to call `advance(_:)`.)
func withCore<R>(
    model: sending Model = Model(),
    client: Client = .mock(),
    clock: any Clock<Duration> = ImmediateClock(),
    now: @escaping @Sendable () -> Date = Date.init,
    isolation: isolated TestActor = TestActor(),
    body: @Sendable (isolated TestActor, Core) async throws -> R
) async throws -> R {
    let dependencies = Dependencies(date: DateGenerator(now), client: client, clock: clock)
    return try await Dependencies.$current.withValue(dependencies) {
        let core = makeCore(model: model)
        defer { core.cancelAll() }
        return try await body(isolation, core)
    }
}

/// Suspends until `condition` holds, re-arming `withObservationTracking`
/// on whatever `Model` properties it reads — so a test waits on the
/// actual observable transition (a status flips, a `LoadedStories`
/// populates or clears) instead of guessing how many `runPending()`
/// drains it takes.
///
/// `onChange` fires in the mutation's `willSet`, but the resumed
/// continuation runs after the mutation completes (FIFO on the
/// `TestActor` the writer shares), so the re-check sees the new value;
/// the loop re-arms if not. Deterministic, no polling. A condition that
/// never holds hangs until the test's time limit, by design.
func waitUntil(isolation: isolated any Actor = #isolation, _ condition: () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = condition() } onChange: { continuation.resume() }
        }
    }
}

/// Drains the actor's queue twice — the synchronisation of last resort
/// for the few steps with no observable transition to ``waitUntil(isolation:_:)``
/// on: a listener processing a keystroke that leaves `Model` unchanged
/// (`isLoading` already true), or a cancel-and-replace through parked
/// sleeps. A `model.searchQuery` write resumes the listener as a new job
/// behind the one already running, so a single `runPending()` can return
/// before it runs; the second drain runs it. Prefer ``waitUntil(isolation:_:)``
/// wherever there is a state change to wait on.
func settle(_ isolation: isolated TestActor) async {
    await isolation.runPending()
    await isolation.runPending()
}
