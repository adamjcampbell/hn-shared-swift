import Foundation
import Observation
import HackerNews
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Workhorse for `UICore`. An `actor` whose `unownedExecutor`
/// borrows the host's (SE-0392), so all AppCore methods and Tasks
/// execute on the same serial executor as `UICore` (`MainActor` in
/// production) or `TestCore` (a per-test executor).
///
/// Forwarding `AppState` from the host across this actor boundary
/// uses one transient `nonisolated(unsafe) let` at the host's init
/// call site — nothing inside AppCore uses `nonisolated(unsafe)`.
/// Tasks spawned inside AppCore methods inherit this actor via the
/// implicit `self` references in their bodies (Task.init's built-in
/// `@_inheritActorContext`), so the listener / commit Tasks read
/// and write `state` directly.
///
/// Not bridged to Kotlin; `UICore` re-exposes the public surface.
actor AppCore {
    let state: AppState

    private let commandsContinuation: AsyncStream<AppCommand>.Continuation
    nonisolated let commands: AsyncStream<AppCommand>
    private let client: Client
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private nonisolated let borrowed: any Actor

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        borrowed.unownedExecutor
    }

    enum TaskID { case feed, feedMore, search, searchCommit, searchMore, searchListener }
    private var tasks = TaskRegistry<TaskID>()

    /// Debounce window between a `state.searchQuery` write and the
    /// resulting fetch. Static so tests can name the same duration
    /// when advancing their `TestClock`.
    static let searchDebounce: Duration = .milliseconds(250)

    init(
        state: AppState,
        commands: AsyncStream<AppCommand>,
        commandsContinuation: AsyncStream<AppCommand>.Continuation,
        client: Client,
        clock: any Clock<Duration>,
        now: @escaping @Sendable () -> Date = Date.init,
        borrowing isolation: any Actor
    ) {
        self.state = state
        self.commands = commands
        self.commandsContinuation = commandsContinuation
        self.client = client
        self.clock = clock
        self.now = now
        self.borrowed = isolation
    }

    /// Start the long-running search-query listener. Called by the
    /// host once after construction; can't go in `init` because
    /// Swift forbids reassigning an actor stored property from a
    /// sync init body.
    func startListener() {
        tasks[.searchListener] = Task {
            for await query in state.searchQueryChanges {
                if query.isEmpty {
                    tasks[.search] = nil
                    tasks[.searchCommit] = nil
                    tasks[.searchMore] = nil
                    state.search = LoadableStories()
                } else {
                    scheduleSearchFetch(query: query)
                }
            }
        }
    }

    /// Fire-and-forget debounced search. Parks the network call in
    /// `tasks[.search]` (cancellable by a newer keystroke or by the
    /// listener's empty-query path) and the post-await commit in
    /// `tasks[.searchCommit]`. The split slot is what closes the race
    /// where a clearSearch lands between `task.value` resolving and
    /// the state write — cancelling `[.searchCommit]` drops the
    /// commit before it repopulates cleared state.
    private func scheduleSearchFetch(query: String) {
        tasks[.searchMore] = nil
        // Skip no-op writes during keystroke bursts — re-firing
        // @Observable notifications would trigger SwiftUI / Compose
        // recomposition per character.
        if state.search.loadMoreStatus != LoadStatus() {
            state.search.loadMoreStatus = LoadStatus()
        }
        if !state.search.initialStatus.isLoading {
            state.search.initialStatus.startLoading()
        }

        let task = makeFetchTask(debounce: Self.searchDebounce) { client in
            try await client.search(query, 0)
        }
        tasks[.search] = task

        tasks[.searchCommit] = Task {
            do {
                let page = try await task.value
                try Task.checkCancellation()
                for story in page.stories { state.stories[story.id] = story }
                let ids = page.stories.map(\.id)
                state.search.receiveInitialPage(ids, totalPages: page.totalPages, loadedAt: now())
            } catch is CancellationError {
            } catch {
                state.search.initialStatus.finishFailure(error.localizedDescription)
            }
        }
    }

    /// Single entry point for every user-driven mutation. Each arm
    /// holds the entire flow for its event — the explicit
    /// feed/search and refresh/loadMore duplication is the point:
    /// each path reads top-to-bottom without jumping between helpers.
    func sendEvent(_ event: AppEvent) async {
        switch event {

        case .toggleRead(let id):
            if state.readIds.contains(id) {
                state.readIds.remove(id)
            } else {
                state.readIds.insert(id)
            }

        case .openStory(let id):
            guard let story = state.stories[id] else { return }
            state.readIds.insert(id)
            if let url = story.url {
                commandsContinuation.yield(.presentURL(value: url))
            }

        case .refresh where state.searchQuery.isEmpty:
            // Feed refresh — page 0. Supersedes any in-flight
            // load-more (otherwise its appended page would land on
            // the snapshot we're about to replace) and resets its
            // status.
            tasks[.feedMore] = nil
            state.feed.loadMoreStatus = LoadStatus()
            state.feed.initialStatus.startLoading()

            let task = makeFetchTask(debounce: nil) { try await $0.frontPage(0) }
            tasks[.feed] = task
            do {
                let page = try await task.value
                for story in page.stories { state.stories[story.id] = story }
                let ids = page.stories.map(\.id)
                state.feed.receiveInitialPage(ids, totalPages: page.totalPages, loadedAt: now())
            } catch is CancellationError {
                // Newer fetch will clear loading when it commits.
            } catch {
                state.feed.initialStatus.finishFailure(error.localizedDescription)
            }

        case .refresh:
            // Search refresh — page 0 with the current query. Cancels
            // the listener's commit wrapper too so the registry slot
            // doesn't keep pointing at a stale task.
            let query = state.searchQuery
            tasks[.searchMore] = nil
            tasks[.searchCommit] = nil
            state.search.loadMoreStatus = LoadStatus()
            state.search.initialStatus.startLoading()

            let task = makeFetchTask(debounce: nil) { try await $0.search(query, 0) }
            tasks[.search] = task
            do {
                let page = try await task.value
                for story in page.stories { state.stories[story.id] = story }
                let ids = page.stories.map(\.id)
                state.search.receiveInitialPage(ids, totalPages: page.totalPages, loadedAt: now())
            } catch is CancellationError {
            } catch {
                state.search.initialStatus.finishFailure(error.localizedDescription)
            }

        case .loadMore where state.searchQuery.isEmpty:
            guard let loaded = state.feed.loadedStories, loaded.hasMore,
                  !state.feed.loadMoreStatus.isLoading else { return }
            let next = loaded.nextPage
            state.feed.loadMoreStatus.startLoading()

            let task = makeFetchTask(debounce: nil) { try await $0.frontPage(next) }
            tasks[.feedMore] = task
            do {
                let page = try await task.value
                for story in page.stories { state.stories[story.id] = story }
                let ids = page.stories.map(\.id)
                state.feed.receiveLoadMorePage(ids, totalPages: page.totalPages)
            } catch is CancellationError {
            } catch {
                state.feed.loadMoreStatus.finishFailure(error.localizedDescription)
            }

        case .loadMore:
            guard let loaded = state.search.loadedStories, loaded.hasMore,
                  !state.search.loadMoreStatus.isLoading else { return }
            let query = state.searchQuery
            let next = loaded.nextPage
            state.search.loadMoreStatus.startLoading()

            let task = makeFetchTask(debounce: nil) { try await $0.search(query, next) }
            tasks[.searchMore] = task
            do {
                let page = try await task.value
                for story in page.stories { state.stories[story.id] = story }
                let ids = page.stories.map(\.id)
                state.search.receiveLoadMorePage(ids, totalPages: page.totalPages)
            } catch is CancellationError {
            } catch {
                state.search.loadMoreStatus.finishFailure(error.localizedDescription)
            }
        }
    }

    /// Test-only teardown — production `UICore` is app-lifetime.
    /// Without this, the TaskRegistry → listener-Task → self cycle
    /// keeps the actor alive past test scope.
    func shutdown() {
        tasks.cancelAll()
    }

    /// Build a fetch task that sleeps for `debounce` (if set), then
    /// runs `body`. Captures only Sendable values (`client`, `clock`).
    ///
    /// **`try` on the sleep is load-bearing.** A test-mock that
    /// doesn't honor cancellation would otherwise fall through to the
    /// network call and commit stale data; the throw propagating is
    /// what makes cancel-and-replace robust against any client impl.
    ///
    /// **`URLError(.cancelled)` → `CancellationError`.** `URLSession`
    /// surfaces task cancellation as `URLError.cancelled`, which would
    /// otherwise be reported as a transient error rather than a silent
    /// supersede.
    private func makeFetchTask(
        debounce: Duration?,
        body: @Sendable @escaping (Client) async throws -> Page
    ) -> Task<Page, Error> {
        Task { [client, clock] in
            if let debounce {
                try await clock.sleep(for: debounce)
            }
            try Task.checkCancellation()
            do {
                return try await body(client)
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            }
        }
    }
}
