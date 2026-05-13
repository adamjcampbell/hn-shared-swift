import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Workhorse for `UICore`. Non-`Sendable` `final class`; async and
/// Task-spawning methods take `isolation: isolated (any Actor)? =
/// #isolation` (SE-0420) so they inherit the caller's isolation
/// statically.
///
/// Not bridged to Kotlin; `UICore` re-exposes the public surface.
final class AppCore {
    let state: AppState

    private let commandsContinuation: AsyncStream<AppCommand>.Continuation
    let commands: AsyncStream<AppCommand>
    private let client: HNClient
    private let clock: any Clock<Duration>

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
        client: HNClient,
        clock: any Clock<Duration>,
        isolation: isolated (any Actor)? = #isolation
    ) {
        self.state = state
        self.commands = commands
        self.commandsContinuation = commandsContinuation
        self.client = client
        self.clock = clock

        // Listener for `state.searchQuery` writes (iOS @Bindable,
        // Android textFieldState collector). Empty → clear the search
        // surface and cancel anything in flight. Non-empty → schedule
        // a debounced fetch fire-and-forget: the body must return to
        // `for await` before the network call completes so the *next*
        // keystroke can cancel-and-replace the parked task.
        tasks[.searchListener] = isolatedTask { [self] in
            for await query in state.searchQueryChanges {
                if query.isEmpty {
                    tasks[.search] = nil
                    tasks[.searchCommit] = nil
                    tasks[.searchMore] = nil
                    state.search = LoadableHits()
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
    ///
    /// Lives outside the listener body because Swift can't propagate
    /// region isolation through nested `@isolated(any)` closures; the
    /// explicit `isolation:` parameter gives the inner `isolatedTask`
    /// a static actor to inherit.
    private func scheduleSearchFetch(
        query: String,
        isolation: isolated (any Actor)? = #isolation
    ) {
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

        tasks[.searchCommit] = isolatedTask { [self] in
            do {
                let page = try await task.value
                try Task.checkCancellation()
                let ids = state.upsert(page)
                state.search.receiveInitialPage(ids, totalPages: page.totalPages)
            } catch is CancellationError {
                // Newer keystroke (or clearSearch) cancelled us.
            } catch {
                state.search.initialStatus.finishFailure(error.localizedDescription)
            }
        }
    }

    /// Single entry point for every user-driven mutation. Each arm
    /// holds the entire flow for its event — the explicit
    /// feed/search and refresh/loadMore duplication is the point:
    /// each path reads top-to-bottom without jumping between helpers.
    func dispatch(_ event: AppEvent, isolation: isolated (any Actor)? = #isolation) async {
        switch event {

        case .toggleRead(let id):
            if state.readIds.contains(id) {
                state.readIds.remove(id)
            } else {
                state.readIds.insert(id)
            }

        case .openStory(let id):
            guard let hit = state.hits[id] else { return }
            state.readIds.insert(id)
            if let url = hit.url {
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
                let ids = state.upsert(page)
                state.feed.receiveInitialPage(ids, totalPages: page.totalPages)
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
                let ids = state.upsert(page)
                state.search.receiveInitialPage(ids, totalPages: page.totalPages)
            } catch is CancellationError {
            } catch {
                state.search.initialStatus.finishFailure(error.localizedDescription)
            }

        case .loadMore where state.searchQuery.isEmpty:
            guard let loaded = state.feed.loadedHits, loaded.hasMore,
                  !state.feed.loadMoreStatus.isLoading else { return }
            let next = loaded.nextPage
            state.feed.loadMoreStatus.startLoading()

            let task = makeFetchTask(debounce: nil) { try await $0.frontPage(next) }
            tasks[.feedMore] = task
            do {
                let page = try await task.value
                let ids = state.upsert(page)
                state.feed.receiveLoadMorePage(ids, totalPages: page.totalPages)
            } catch is CancellationError {
            } catch {
                state.feed.loadMoreStatus.finishFailure(error.localizedDescription)
            }

        case .loadMore:
            guard let loaded = state.search.loadedHits, loaded.hasMore,
                  !state.search.loadMoreStatus.isLoading else { return }
            let query = state.searchQuery
            let next = loaded.nextPage
            state.search.loadMoreStatus.startLoading()

            let task = makeFetchTask(debounce: nil) { try await $0.search(query, next) }
            tasks[.searchMore] = task
            do {
                let page = try await task.value
                let ids = state.upsert(page)
                state.search.receiveLoadMorePage(ids, totalPages: page.totalPages)
            } catch is CancellationError {
            } catch {
                state.search.loadMoreStatus.finishFailure(error.localizedDescription)
            }
        }
    }

    /// Test-only teardown — production `UICore` is app-lifetime. The
    /// listener captures `[self]`, so without this the
    /// TaskRegistry → listener-Task → self cycle keeps the core
    /// alive past test scope.
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
        body: @Sendable @escaping (HNClient) async throws -> HNPage
    ) -> Task<HNPage, Error> {
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

/// Spawn an unstructured `Task` whose body runs on the caller's
/// isolation. `sending @isolated(any)` carries that isolation through
/// the inner `Task`'s `@Sendable` boundary so the closure can capture
/// non-Sendable values (e.g. `self` on `AppCore`).
func isolatedTask(
    isolation: isolated (any Actor)? = #isolation,
    _ body: sending @escaping @isolated(any) () async -> Void
) -> Task<Void, Never> {
    Task { await body() }
}
