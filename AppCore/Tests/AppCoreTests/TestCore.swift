import Foundation
@testable import AppCore

/// Per-test isolation shell. Each `TestCore` instance is its own
/// `actor` with its own executor; the `AppCore` workhorse it owns is
/// a non-Sendable class constructed in this actor's isolation.
///
/// Different `TestCore` instances → different executors → state
/// mutations across tests run in parallel.
///
/// All access — reads, writes, and workhorse calls — flows through
/// `core.run { … }` (Point-Free `Actor.run`, Video #362). Multiple
/// reads grouped inside a single `run` block share one isolation hop
/// AND a single consistent snapshot of state (Video #364 "Isolation:
/// Performance" — the "smart actor" pattern that prevents
/// interleaved reads from seeing inconsistent state).
public actor TestCore {
    public let state: AppState
    public nonisolated let commands: AsyncStream<AppCommand>
    let appCore: AppCore

    public init(
        client: HNClient = HNClient(),
        clock: any Clock<Duration> = ContinuousClock()
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
            clock: clock
        )
    }

    /// Mirrors `AppCore.searchDebounce` so test sites can say
    /// `TestCore.searchDebounce` instead of `AppCore.searchDebounce`,
    /// keeping the test surface in terms of the test shell.
    public static let searchDebounce: Duration = AppCore.searchDebounce
}

/// Point-Free `Actor.run` pattern (Video #362). Tests batch multiple
/// reads + workhorse calls into one isolation hop with a consistent
/// snapshot — no state changes can interleave between assertions inside
/// the block.
///
/// ```swift
/// await core.run { await $0.appCore.dispatch(.refresh) }
/// await core.run { core in
///     #expect(core.state.feedStories.count == 2)
///     #expect(core.state.feed.loadedHits?.loadedAt != nil)
/// }
/// ```
extension TestCore {
    func run<R, Failure: Error>(
        _ body: sending @Sendable (isolated TestCore) async throws(Failure) -> R
    ) async throws(Failure) -> R {
        try await body(self)
    }
}
