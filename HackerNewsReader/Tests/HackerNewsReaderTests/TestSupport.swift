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
/// on whatever observable properties it reads — `Model` fields (a status
/// flips, a `LoadedStories` populates or clears) or `core.tasks` slots
/// (a fetch is registered, replaced, or removed; `Task` is `Equatable`,
/// so `tasks[.search] != before` waits for a cancel-and-replace) — so a
/// test waits on the actual transition instead of guessing how many
/// `runPending()` drains it takes.
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
