import Dispatch
import Foundation
@testable import HackerNewsReader
import HackerNews

/// Per-test isolation shell. Each `TestCore` is its own actor —
/// different instances run on different executors, so tests parallelise.
/// All access flows through `core.run { … }`, which gives the closure
/// a single consistent snapshot for grouped reads.
///
/// `unownedExecutor` is overridden to a private `DispatchSerialQueue`
/// (SE-0392) so tests can call `await core.settle()` for a FIFO-
/// deterministic drain instead of `Task.megaYield()`. The pattern is
/// straight from Point-Free Video #362; the FIFO trade-off (real
/// actors honour task priority) is acceptable because test code has
/// no priority diversity.
public actor TestCore {
    public let state: AppState
    public nonisolated let commands: AsyncStream<AppCommand>
    private nonisolated let executorQueue = DispatchSerialQueue(label: "TestCore.executor")
    let appCore: AppCore

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executorQueue.asUnownedSerialExecutor()
    }

    public init(
        client: Client = Client(),
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let state = AppState()
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.state = state
        self.commands = stream
        self.appCore = AppCore(
            state: state,
            commands: stream,
            commandsContinuation: continuation,
            client: client,
            clock: clock,
            now: now
        )
    }

    public static let searchDebounce: Duration = AppCore.searchDebounce

    /// Break the `TaskRegistry → listener-Task → AppCore` cycle when
    /// the test scope exits. Production `UICore` is app-lifetime so it
    /// doesn't need this; tests churn TestCores and would leak the
    /// listener task without it. Requires SE-0371 (Swift 6.2).
    isolated deinit {
        appCore.shutdown()
    }

    /// Wait until every job queued on this actor's executor at the
    /// moment of call has finished, plus any jobs those jobs
    /// synchronously enqueue. Replaces `Task.megaYield()` with a
    /// FIFO-deterministic drain: the continuation-resume below sits at
    /// the back of `executorQueue`, so awaiting it returns only after
    /// the queue has settled past this point.
    ///
    /// Tasks suspended on `clock.sleep` aren't re-enqueued until the
    /// clock advances — same boundary as megaYield.
    public nonisolated func settle() async {
        await withCheckedContinuation { continuation in
            executorQueue.async { continuation.resume() }
        }
    }
}

/// Point-Free `Actor.run` pattern (Video #362). Tests batch multiple
/// reads + workhorse calls into one isolation hop with a consistent
/// snapshot — no state changes can interleave between assertions inside
/// the block.
///
/// ```swift
/// await core.run { await $0.appCore.sendEvent(.refresh) }
/// await core.run { core in
///     #expect(core.state.feedStories.count == 2)
///     #expect(core.state.feed.loadedStories?.loadedAt != nil)
/// }
/// ```
extension TestCore {
    func run<R, Failure: Error>(
        _ body: sending @Sendable (isolated TestCore) async throws(Failure) -> R
    ) async throws(Failure) -> R {
        try await body(self)
    }
}
