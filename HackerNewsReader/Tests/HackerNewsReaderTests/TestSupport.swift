import Foundation
@testable import HackerNewsReader
import HackerNews

extension AppCore {
    /// Tests always construct AppCore with `TestActor` isolation;
    /// recover it here so per-test code can `await appCore.testActor
    /// .settle()` without threading the TestActor as a separate local.
    /// Force cast is sound because this target only constructs AppCore
    /// via `withAppCore`, which always passes a TestActor.
    nonisolated var testActor: TestActor { isolation as! TestActor }
}

/// Per-test AppCore fixture. Builds the actor (with its `TestActor`
/// isolation, the supplied `Client` / clock / now), runs `body`, and
/// awaits `appCore.shutdown()` on exit so the listener Task is
/// cancelled deterministically before the next test starts.
///
/// `state` reaches the body via the closure parameter under SE-0414
/// region isolation; the `nonisolated(unsafe)` rebind mirrors what
/// `makeAppCore()` does in production (Core.swift).
func withAppCore<R>(
    client: Client = .mock(),
    clock: any Clock<Duration> = ContinuousClock(),
    now: @escaping @Sendable () -> Date = Date.init,
    body: (AppState, AsyncStream<AppCommand>, AppCore) async throws -> R
) async rethrows -> R {
    let testActor = TestActor()
    nonisolated(unsafe) let state = AppState()
    let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
    let appCore = AppCore(
        state: state,
        commandsContinuation: continuation,
        client: client,
        clock: clock,
        now: now,
        isolation: testActor
    )
    // Swift forbids `await` inside `defer` in async funcs, so the
    // teardown is mirrored on both arms.
    do {
        let result = try await body(state, stream, appCore)
        await appCore.shutdown()
        return result
    } catch {
        await appCore.shutdown()
        throw error
    }
}
