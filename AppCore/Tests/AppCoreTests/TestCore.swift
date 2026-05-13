import Foundation
@testable import AppCore

/// Per-test isolation shell. Each `TestCore` instance is its own
/// `actor` with its own executor; the `AppCore` workhorse it owns is
/// a non-Sendable class constructed in this actor's isolation. The
/// Point-Free `Actor.run` pattern (Video #362) is the entry point for
/// tests that need to touch the workhorse — `core.run { … }` gives
/// the closure synchronous access to the actor's isolated storage
/// (including the non-Sendable `handler`).
///
/// Different `TestCore` instances → different executors → state
/// mutations across tests run in parallel.
///
/// `TestCore` is the test-target counterpart to `UICore`. Keeps just
/// the stored shape (state + handler + commands) and Sendable read
/// accessors for ergonomic assertions; all method dispatch flows
/// through `core.run { … }` rather than per-method forwarders.
public actor TestCore {
    public let state: AppState
    public nonisolated let commands: AsyncStream<AppCommand>
    let handler: AppCore

    public init(
        client: HNClient = HNClient(),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        let state = AppState()
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.state = state
        self.commands = stream
        self.handler = AppCore(
            state: state,
            commands: stream,
            commandsContinuation: continuation,
            client: client,
            clock: clock
        )
        handler.bootstrap()
    }

    // MARK: - Named Sendable read accessors

    /// Mirror the AppState properties tests actually read. Each is an
    /// actor-isolated property returning a Sendable value, so
    /// `await testCore.foo` reads with one actor hop. For non-Sendable
    /// reads or mutations, use `core.run { … }`.
    public var searchQuery: String { state.searchQuery }
    public var searchQueryChanges: AsyncStream<String> { state.searchQueryChanges }
    public var feed: LoadableHits { state.feed }
    public var search: LoadableHits { state.search }
    public var feedStories: [Story] { state.feedStories }
    public var searchResults: [Story] { state.searchResults }
    public var readIds: Set<String> { state.readIds }

    /// Mirrors `AppCore.searchDebounce` so test sites can say
    /// `TestCore.searchDebounce` instead of `AppCore.searchDebounce`,
    /// keeping the test surface in terms of the test shell.
    public static let searchDebounce: Duration = AppCore.searchDebounce
}

/// Point-Free `Actor.run` pattern (Video #362 *Isolation: Actor
/// Enqueuing*). Lets tests batch multiple state reads + workhorse
/// calls into one isolation hop:
///
/// ```swift
/// await core.run { await $0.handler.dispatch(.refresh) }
/// let stories = await core.run { $0.state.feedStories }
/// ```
///
/// Equivalent to per-method forwarders but generic — any future
/// `AppCore` method is reachable without growing `TestCore`. The
/// closure is `sending` (not `@Sendable`) so it can capture
/// non-Sendable values from the caller's region and transfer them
/// into the actor's region; the `isolated Self` parameter makes the
/// body synchronously isolated to the actor.
extension Actor {
    public func run<R: Sendable, Failure: Error>(
        _ body: sending @escaping @Sendable (isolated Self) async throws(Failure) -> R
    ) async throws(Failure) -> R {
        try await body(self)
    }
}
