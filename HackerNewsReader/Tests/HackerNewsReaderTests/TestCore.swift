import Dispatch
import Foundation
@testable import HackerNewsReader
import HackerNews

/// Per-test isolation shell. Each `TestCore` runs on its own
/// `DispatchSerialQueue` (SE-0392 `unownedExecutor`) so tests
/// parallelise across instances and `await core.settle()` gives a
/// FIFO-deterministic drain (Point-Free Video #362 pattern).
///
/// `AppCore` is constructed with `borrowing: executor` (not `self`),
/// dodging the chicken-and-egg of passing TestCore.self to an init
/// before `self.appCore` is set. Both `TestCore` and `AppCore`
/// borrow the same `BorrowedExecutor` queue, so they share one
/// physical serial executor.
public actor TestCore {
    public let state: AppState
    public nonisolated let commands: AsyncStream<AppCommand>
    private nonisolated let executor: BorrowedExecutor
    let appCore: AppCore

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.unownedExecutor
    }

    public init(
        client: Client = Client(),
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) async {
        let executor = BorrowedExecutor(label: "TestCore.executor")
        let state = AppState()
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.executor = executor
        self.state = state
        self.commands = stream
        // Same transient escape hatch as in `UICore.init` — see there
        // for the rationale.
        nonisolated(unsafe) let forAppCore = state
        let appCore = AppCore(
            state: forAppCore,
            commands: stream,
            commandsContinuation: continuation,
            client: client,
            clock: clock,
            now: now,
            borrowing: executor
        )
        self.appCore = appCore
        await appCore.startListener()
    }

    public static let searchDebounce: Duration = AppCore.searchDebounce

    /// Break the `TaskRegistry → listener-Task → AppCore` cycle when
    /// the test scope exits. Production `UICore` is app-lifetime so it
    /// doesn't need this; tests churn TestCores and would leak the
    /// listener task without it. Requires SE-0371 (Swift 6.2).
    isolated deinit {
        Task { [appCore] in await appCore.shutdown() }
    }

    /// Wait until every job queued on this actor's executor at the
    /// moment of call has finished, plus any jobs those jobs
    /// synchronously enqueue. Replaces `Task.megaYield()` with a
    /// FIFO-deterministic drain: the continuation-resume below sits at
    /// the back of `executor.queue`, so awaiting it returns only after
    /// the queue has settled past this point.
    ///
    /// Tasks suspended on `clock.sleep` aren't re-enqueued until the
    /// clock advances — same boundary as megaYield.
    public nonisolated func settle() async {
        await withCheckedContinuation { continuation in
            executor.queue.async { continuation.resume() }
        }
    }
}

/// Sibling actor that owns the `DispatchSerialQueue` shared by
/// `TestCore` and `AppCore`. Both borrow its `unownedExecutor` —
/// dodges the chicken-and-egg of passing `TestCore.self` to
/// `AppCore.init` from within `TestCore.init`.
actor BorrowedExecutor {
    nonisolated let queue: DispatchSerialQueue

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(label: String) {
        self.queue = DispatchSerialQueue(label: label)
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
