import Clocks
import Foundation
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
/// timing run faster (and need fewer `runPending` calls) with that
/// sleep elided. Override with `clock: TestClock()` when the test
/// asserts on debounce timing, and pass the same clock to
/// ``commitSearch(_:core:clock:isolation:)``.
///
/// - Note: `makeCore` runs inside `Dependencies.$date.withValue` so the
///   listener `Task` it spawns inherits the pinned `now`.
/// Drains the actor's queue twice. A `model.searchQuery` write resumes
/// the listener suspended on `searchQueryChanges`, but `AsyncStream`
/// schedules that resume as a *new* job behind the one already running,
/// so a single `runPending()` returns before the listener has run. The
/// second drain runs the listener job (and `applySearchQuery`, which is
/// synchronous, completes within it). Two is the minimal deterministic
/// count for "write a query, then observe its effect" — this is serial-
/// queue job ordering, not a data race, so it does not depend on load.
func settle(_ isolation: isolated TestActor) async {
    await isolation.runPending()
    await isolation.runPending()
}

func withCore<R>(
    model: sending Model = Model(),
    client: Client = .mock(),
    clock: any Clock<Duration> = ImmediateClock(),
    now: @escaping @Sendable () -> Date = Date.init,
    isolation: isolated TestActor = TestActor(),
    body: @Sendable (isolated TestActor, Core) async throws -> R
) async throws -> R {
    let core = makeCore(model: model, client: client, clock: clock)
    defer { core.cancelAll() }
    return try await Dependencies.$date.withValue(DateGenerator(now)) {
        try await body(isolation, core)
    }
}
