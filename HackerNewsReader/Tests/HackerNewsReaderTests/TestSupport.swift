import Foundation
import Observation
import Testing
@testable import HackerNewsReader
import HackerNews

/// Per-test ``Core`` fixture. Isolated to a fresh ``TestActor`` so
/// `makeCore` (and the whole `body`) run on it: `#isolation` binds
/// there, and every model / registry write stays serialised on that
/// actor. Cancels the listener on exit so the `Task → Model`
/// references release before the next test starts.
///
/// The body runs isolated to the `TestActor`, so reads and
/// `core.sendMessage(_:)` calls share a consistent snapshot between
/// suspension points — no separate `run { … }` batching is needed.
///
/// Default `debounce` is `.zero`: the search fetch runs straight
/// through its sleep, so a test drives a search to completion with
/// `await waitUntil { core.model.searchLoaded != nil }` (or by awaiting
/// the registry's task) and never touches a clock. Tests that assert
/// *window* behaviour — what happens while the debounce is pending —
/// pass ``debounceNeverElapses``: real time never crosses it, so the
/// window deterministically stays open until cancellation (fixture
/// exit) releases the parked sleep.
///
/// - Note: `client` / `debounce` / `now` are bound into ``Dependencies``
///   and `makeCore` runs *inside* the `withValue`, so the listener
///   `Task` it spawns — and every fetch the body triggers — inherits
///   these deps.
func withCore<R>(
    model: sending Model = Model(),
    client: Client = .mock(),
    debounce: Duration = .zero,
    now: @escaping @Sendable () -> Date = Date.init,
    isolation: isolated TestActor = TestActor(),
    body: @Sendable (isolated TestActor, Core) async throws -> R
) async throws -> R {
    var dependencies = Dependencies(date: DateGenerator(now), client: client)
    dependencies.searchDebounce = debounce

    // The defer lives here, in `withCore`'s own isolated frame, not
    // inside the `withValue` operation closure — a closure value's
    // post-await continuation is not reliably pinned to the host actor
    // (TSan), and `cancelAll` mutates the registry.
    var core: Core?
    defer { core?.cancelAll() }

    return try await Dependencies.$current.withValue(dependencies) {
        let made = makeCore(model: model)
        core = made
        return try await body(isolation, made)
    }
}

/// A debounce no test outlives: holds the search-fetch window open so a
/// test can assert mid-window behaviour. The parked `Task.sleep`
/// releases through cancellation, never by elapsing.
let debounceNeverElapses = Duration.seconds(1_000_000)

/// Suspends until `condition` holds, re-arming `withObservationTracking`
/// on whatever observable properties it reads — `Model` fields (a status
/// flips, a `LoadedStories` populates or clears) or `core.tasks` slots
/// (a fetch is registered, replaced, or removed; `Task` is `Equatable`,
/// so `tasks[.search] != before` waits for a cancel-and-replace) — so a
/// test waits on the actual transition instead of guessing how many
/// queue drains it takes.
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

/// Rendezvous for parking a mock mid-call — the clock-free replacement
/// for `clock.sleep(for: .seconds(Int.max))` on a never-advanced
/// `TestClock`.
///
/// The mock calls ``arrive()``: it signals the test and parks. The test
/// awaits ``arrival()`` to know the mock is deterministically *inside*
/// the call (a fetch is mid-flight in the client, not merely
/// registered), then triggers whatever should interrupt it. The park
/// releases when the parked task is cancelled — `for await` ends on
/// cancellation — or when the test calls ``open()``.
///
/// One parker and one awaiter per gate: each side consumes its
/// `AsyncStream`, and streams are single-consumer.
final class Gate: Sendable {
    private let arrivals: AsyncStream<Void>
    private let arrivalsContinuation: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>
    private let releasesContinuation: AsyncStream<Void>.Continuation

    init() {
        (arrivals, arrivalsContinuation) = AsyncStream.makeStream()
        (releases, releasesContinuation) = AsyncStream.makeStream()
    }

    /// Mock side: announce arrival, then park until ``open()`` or
    /// cancellation. Check `Task.isCancelled` after this returns to
    /// tell the two releases apart.
    func arrive() async {
        arrivalsContinuation.yield()
        for await _ in releases { break }
    }

    /// Test side: suspends until the mock reaches ``arrive()``. Returns
    /// immediately if it already has — the arrival buffers.
    func arrival() async {
        for await _ in arrivals { break }
    }

    /// Unparks the mock without cancelling it.
    func open() {
        releasesContinuation.finish()
    }
}
