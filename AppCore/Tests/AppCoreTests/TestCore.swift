import Foundation
@testable import AppCore

/// Per-test isolation shell. Each `TestCore` instance is its own
/// `actor` with its own executor; the `AppCore` workhorse it owns is
/// a non-Sendable class constructed in this actor's isolation, so all
/// `handler.*` calls inherit `TestCore`'s isolation via
/// `isolation: isolated (any Actor)? = #isolation` (SE-0420).
/// Different `TestCore` instances → different executors → state
/// mutations across tests run in parallel.
///
/// `TestCore` is the test-target counterpart to `UICore`. Same pattern:
/// shell owns `AppState`, hands it to the `AppCore` workhorse at init.
/// No `StateAccess` shim, no `assumeIsolated`, no executor-borrowing
/// dance.
///
/// Tests read state via named Sendable accessors (`feedStories`,
/// `searchQuery`, etc.), the `with<T:>(_:)` ad-hoc helper, or — if
/// they need parity with production semantics —
/// `await core.handler.state.foo`.
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
        // `handler.bootstrap()` inherits this actor's isolation
        // (the AppCore is constructed in TestCore's init, so the call
        // is implicitly on TestCore).
        handler.bootstrap()
    }

    // MARK: - Public dispatch surface (mirrors UICore)

    public func dispatch(_ event: AppEvent) async {
        await handler.dispatch(event)
    }

    public func shutdown() {
        handler.shutdown()
    }

    // MARK: - Handler forwards
    //
    // The non-Sendable `AppCore` workhorse can't escape this actor's
    // isolation, so tests can't say `await core.handler.foo()`. These
    // thin forwards expose the workhorse methods that tests drive
    // directly (the dispatch path doesn't cover the fetch/load-more
    // entry points individually).

    public func clearSearch() {
        handler.clearSearch()
    }

    public func runFeedFetch() async {
        await handler.runFeedFetch()
    }

    public func runFeedLoadMore() async {
        await handler.runFeedLoadMore()
    }

    public func runSearchFetch(query: String, debounce: Duration? = nil) async {
        await handler.runSearchFetch(query: query, debounce: debounce)
    }

    public func runSearchLoadMore() async {
        await handler.runSearchLoadMore()
    }

    /// Mirrors `AppCore.searchDebounce` — re-exposed so test sites can
    /// say `TestCore.searchDebounce` instead of `AppCore.searchDebounce`,
    /// keeping the test surface in terms of the test shell.
    public static let searchDebounce: Duration = AppCore.searchDebounce

    // MARK: - Named Sendable read accessors

    /// Mirror the AppState properties tests actually read. Each is
    /// an actor-isolated property returning a Sendable value, so
    /// `await testCore.foo` reads the underlying `state.foo` with
    /// one actor hop.
    public var searchQuery: String { state.searchQuery }
    public var searchQueryChanges: AsyncStream<String> { state.searchQueryChanges }
    public var feed: LoadableHits { state.feed }
    public var search: LoadableHits { state.search }
    public var feedStories: [Story] { state.feedStories }
    public var searchResults: [Story] { state.searchResults }
    public var readIds: Set<String> { state.readIds }

    // MARK: - Ad-hoc reads/writes

    /// Generic state access for tests that need a one-off read,
    /// write, or compound read+write. Body runs on this actor's
    /// isolation; mutations and Sendable returns work the same way.
    public func with<T: Sendable>(_ work: @Sendable (AppState) -> T) -> T {
        work(state)
    }
}
