import Clocks
import Foundation
import Testing
@testable import HackerNewsReader
import HackerNews

extension AppEngine {
    /// Tests construct `AppEngine` with `TestActor` isolation and (by
    /// default) an `ImmediateClock`; these accessors reach the
    /// test-specific instance without threading it as a separate local.
    /// `#require` makes a misuse (production isolation in a test, or a
    /// non-`TestClock` where one is needed) surface as a graceful test
    /// failure, not a trap.
    nonisolated var testActor: TestActor {
        get throws { try #require(isolation as? TestActor) }
    }
    nonisolated var testClock: TestClock<Duration> {
        get throws { try #require(clock as? TestClock<Duration>) }
    }

    /// Batches multiple reads and `sendEvent(_:)` calls into one
    /// isolation hop with a consistent snapshot — no other Task can
    /// interleave between statements inside the block.
    ///
    /// - Parameter body: Closure that runs while isolated to the
    ///   actor; receives `self` as its only argument.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Whatever `body` throws.
    func run<R, Failure: Error>(
        _ body: sending @Sendable (isolated AppEngine) async throws(Failure) -> R
    ) async throws(Failure) -> R {
        try await body(self)
    }
}

/// Per-test `AppEngine` fixture. Builds the actor (with its
/// `TestActor` isolation, the supplied `Client` / clock / now), runs
/// `body`, and awaits `engine.cancelAll()` on exit so the listener
/// Task is cancelled deterministically before the next test starts.
///
/// Default clock is `ImmediateClock`: the only `clock.sleep` in
/// production is the search debounce, and tests that don't validate
/// timing run faster (and need fewer `runPending` calls) with that
/// sleep elided. Override with `clock: TestClock()` when the test
/// asserts on debounce timing.
///
/// - Note: The body's outcome is captured as a `Result` so the
///   teardown runs on a single path before rethrowing via `.get()`;
///   `defer` can't `await`. The stdlib's async
///   `Result.init(catching:)` requires a `@concurrent` closure, but
///   this body captures task-isolated state, so the catch is manual.
func withAppEngine<R>(
    client: Client = .mock(),
    clock: any Clock<Duration> = ImmediateClock(),
    now: @escaping @Sendable () -> Date = Date.init,
    body: (AppEngine) async throws -> R
) async throws -> R {
    let engine = AppEngine(
        state: AppState(),
        client: client,
        clock: clock,
        now: now,
        isolation: TestActor()
    )
    await engine.bind()
    let result: Result<R, Error>
    do { result = .success(try await body(engine)) }
    catch { result = .failure(error) }
    await engine.cancelAll()
    return try result.get()
}
