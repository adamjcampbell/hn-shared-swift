import Foundation
import Observation
import Testing
import os
@testable import HackerNewsReader
import HackerNews

/// Per-test ``Core`` fixture. Isolated to a fresh ``TestActor`` so
/// `makeCore`, the consumer spawner built here, and the whole `body` run
/// on that actor, serialising every model write. Cancels the search
/// consumer on exit so the `Task → Model` references release before the
/// next test.
///
/// The body runs isolated to the `TestActor`, so reads and
/// `core.sendMessage(_:)` calls share a consistent snapshot between
/// suspension points — no separate `run { … }` batching is needed.
///
/// Default `debounce` is `.zero`: the search fetch runs straight
/// through its sleep, so a test drives a search to completion with
/// `await waitUntil { core.model.searchLoaded != nil }` and never touches
/// a clock. Tests that assert *window* behaviour — what happens while the
/// debounce is pending — pass ``debounceNeverElapses``: real time never
/// crosses it, so the window deterministically stays open until
/// cancellation (fixture exit) releases the parked sleep.
///
/// - Note: `client` / `debounce` / `now` are bound into ``Dependencies``
///   and `makeCore` runs *inside* the `withValue`, so the search consumer
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

    // Tests isolate to an actor *instance*, so the spawner captures it
    // (`_ = isolation`) — the dynamic-isolation capture SE-0420 requires
    // for an instance. (Production's `makeAppCore` injects a static
    // `@MainActor` spawner and needs no capture.) `makeCore` uses this
    // spawner for the search consumer and each reload it starts.
    return try await Dependencies.$current.withValue(dependencies) {
        let core = makeCore(model: model, spawn: { work in
            Task { _ = isolation; await work() }
        })
        defer { core.cancelAll() }
        return try await body(isolation, core)
    }
}

/// A debounce no test outlives: holds the search-fetch window open so a
/// test can assert mid-window behaviour. The parked `Task.sleep`
/// releases through cancellation, never by elapsing.
let debounceNeverElapses = Duration.seconds(1_000_000)

/// Suspends until `condition` holds, re-arming `withObservationTracking`
/// on whatever observable `Model` fields it reads — a status flips, a
/// `LoadedStories` populates or clears — so a test waits on the actual
/// transition instead of guessing how many queue drains it takes.
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

/// Rendezvous for parking a mock mid-call, so a test can interrupt a
/// fetch while it is genuinely in flight.
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

/// A park that *ignores* cancellation: the parked task resumes only when
/// the test calls ``release()``, never on cancellation — unlike ``Gate``,
/// whose `arrive()` unparks when its task is cancelled. Models a fetch
/// whose network round-trip completes *after* the work was cancelled
/// (cancel losing the race), so a superseded ``Latest`` slot delivers a
/// value rather than throwing. ``arrival()`` lets the test wait until the
/// parked task is genuinely inside ``wait()`` before interrupting it.
///
/// One parker and one arrival-waiter per hold.
final class Hold: Sendable {
    private struct State {
        var waiter: CheckedContinuation<Void, Never>?
        var released = false
        var arrivalWaiter: CheckedContinuation<Void, Never>?
        var arrived = false
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// Parked side: announce arrival, then suspend until ``release()``,
    /// ignoring cancellation.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.withLock { s in
                s.arrived = true
                s.arrivalWaiter?.resume()
                s.arrivalWaiter = nil
                if s.released { continuation.resume() } else { s.waiter = continuation }
            }
        }
    }

    /// Test side: suspend until the parked task reaches ``wait()``.
    func arrival() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.withLock { s in
                if s.arrived { continuation.resume() } else { s.arrivalWaiter = continuation }
            }
        }
    }

    /// Resume the parked task.
    func release() {
        state.withLock { s in
            s.released = true
            s.waiter?.resume()
            s.waiter = nil
        }
    }
}
