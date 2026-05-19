import Clocks
import Foundation
import Testing
@testable import HackerNewsReader
import HackerNews

extension AppCore {
    /// Tests construct `AppCore` with `TestActor` isolation and (by default)
    /// an `ImmediateClock`; these accessors reach the test-specific instance
    /// without threading it as a separate local. `#require` makes a misuse
    /// (production isolation in a test, or a non-`TestClock` where one is
    /// needed) surface as a graceful test failure, not a trap.
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
        _ body: sending @Sendable (isolated AppCore) async throws(Failure) -> R
    ) async throws(Failure) -> R {
        try await body(self)
    }
}

/// Per-test AppCore fixture. Builds the actor (with its `TestActor`
/// isolation, the supplied `Client` / clock / now), runs `body`, and
/// awaits `appCore.shutdown()` on exit so the listener Task is
/// cancelled deterministically before the next test starts.
///
/// Default clock is `ImmediateClock`: the only `clock.sleep` in
/// production is the 250 ms search debounce, and tests that don't
/// validate timing run faster (and need fewer `runPending` calls)
/// with that sleep elided. Override with `clock: TestClock()` when
/// the test asserts on debounce timing.
///
/// Capturing the throwing body's outcome as a `Result` lets shutdown
/// run on a single path before rethrowing via `.get()` — `defer` can't
/// `await`, so the `Result` is what collapses the dual-arm `do/catch`
/// the previous shape needed. (The stdlib's async `Result.init(catching:)`
/// requires a `@concurrent` closure; this body captures task-isolated
/// state, so it's done manually.)
func withAppCore<R>(
    client: Client = .mock(),
    clock: any Clock<Duration> = ImmediateClock(),
    now: @escaping @Sendable () -> Date = Date.init,
    body: (AppCore) async throws -> R
) async throws -> R {
    let appCore = AppCore(
        state: AppState(),
        client: client,
        clock: clock,
        now: now,
        isolation: TestActor()
    )
    let result: Result<R, Error>
    do { result = .success(try await body(appCore)) }
    catch { result = .failure(error) }
    await appCore.shutdown()
    return try result.get()
}
