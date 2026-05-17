import Foundation
import Observation
import HackerNews
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Event-handling workhorse. An `actor` whose `unownedExecutor`
/// borrows the host's (SE-0392), so all AppCore methods and Tasks
/// run isolated to the same actor as the host — MainActor in
/// production (`Core.swift`) or a per-test executor in `TestCore`.
///
/// Forwarding `AppState` from the host into this actor uses one
/// transient `nonisolated(unsafe) let` at the host's init call
/// site — both references stay in the same isolation region
/// (SE-0414), so nothing inside AppCore needs `nonisolated(unsafe)`.
/// Tasks spawned inside AppCore methods inherit this actor via the
/// implicit `self` references in their bodies (Task.init's built-in
/// `@_inheritActorContext`), so the commit / fetch Tasks read and
/// write `state` directly.
///
/// The long-running search-query listener is bootstrapped from
/// `init` via a `(isolated AppCore) -> Void` closure — Task spawned
/// in a sync init body doesn't inherit actor isolation, so the
/// isolated-parameter closure is the route that lets the listener
/// reach `state` and `tasks` without going through `await`. The
/// debounced search-fetch flow lives inline inside that listener;
/// an earlier `final class` topology factored it out as
/// `scheduleSearchFetch` to work around an SE-0461 region-isolation
/// hole that no longer applies under the actor model.
///
/// Not bridged to Kotlin; the module-level `sendEvent` /
/// `sendEventAsync` / `commands` in `Core.swift` are the bridged
/// surface.
actor AppCore {
    let state: AppState

    private let commandsContinuation: AsyncStream<AppCommand>.Continuation
    private let client: Client
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private nonisolated let isolation: any Actor

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        isolation.unownedExecutor
    }

    enum TaskID { case feed, feedMore, search, searchCommit, searchMore, searchListener }
    private var tasks = TaskRegistry<TaskID>()

    /// Debounce window between a `state.searchQuery` write and the
    /// resulting fetch. Static so tests can name the same duration
    /// when advancing their `TestClock`.
    static let searchDebounce: Duration = .milliseconds(250)

    init(
        state: AppState,
        commandsContinuation: AsyncStream<AppCommand>.Continuation,
        client: Client,
        clock: any Clock<Duration>,
        now: @escaping @Sendable () -> Date = Date.init,
        isolation: any Actor
    ) {
        self.state = state
        self.commandsContinuation = commandsContinuation
        self.client = client
        self.clock = clock
        self.now = now
        self.isolation = isolation

        let asyncSetup: @Sendable (isolated AppCore) -> Void = { core in
            let state = core.state
            var tasks: TaskRegistry<TaskID> {
                get { core.tasks }
                set { core.tasks = newValue }
            }

            tasks[.searchListener] = Task {
                for await query in state.searchQueryChanges {
                    if query.isEmpty {
                        tasks[.search] = nil
                        tasks[.searchCommit] = nil
                        tasks[.searchMore] = nil
                        state.searchLoaded = nil
                        state.searchInitialStatus = LoadStatus()
                        state.searchLoadMoreStatus = LoadStatus()
                        continue
                    }

                    // Fire-and-forget debounced search. Parks the network
                    // call in `tasks[.search]` (cancellable by a newer
                    // keystroke or by the empty-query path above) and the
                    // post-await commit in `tasks[.searchCommit]`. The
                    // split slot closes the race where a clearSearch
                    // lands between `task.value` resolving and the state
                    // write — cancelling `[.searchCommit]` drops the
                    // commit before it repopulates cleared state.
                    tasks[.searchMore] = nil
                    // Skip no-op writes during keystroke bursts —
                    // re-firing @Observable notifications would trigger
                    // SwiftUI / Compose recomposition per character.
                    if state.searchLoadMoreStatus != LoadStatus() {
                        state.searchLoadMoreStatus = LoadStatus()
                    }
                    if !state.searchInitialStatus.isLoading {
                        state.searchInitialStatus.startLoading()
                    }

                    let task = core.makeFetchTask(debounce: Self.searchDebounce) { client in
                        try await client.search(query, 0)
                    }
                    tasks[.search] = task

                    tasks[.searchCommit] = Task {
                        do {
                            let page = try await task.value
                            try Task.checkCancellation()
                            for story in page.stories { state.stories[story.id] = story }
                            let ids = page.stories.map(\.id)
                            state.searchLoaded = LoadedStories(
                                ids: ids, page: 0, totalPages: page.totalPages, loadedAt: core.now()
                            )
                            state.searchInitialStatus.finishSuccess()
                        } catch is CancellationError {
                        } catch {
                            state.searchInitialStatus.finishFailure(error.localizedDescription)
                        }
                    }
                }
            }
        }

        Task { await asyncSetup(self) }
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

        case .refresh:
            // Feed refresh — page 0. Always refreshes the feed; the
            // only UI surface that fires `.refresh` is the feed's
            // pull-to-refresh (`.refreshable` on iOS, `PullToRefreshBox`
            // on Android), neither of which is reachable while a search
            // is active. Supersedes any in-flight feed load-more
            // (otherwise its appended page would land on the snapshot
            // we're about to replace) and resets its status.
            tasks[.feedMore] = nil
            state.feedLoadMoreStatus = LoadStatus()
            state.feedInitialStatus.startLoading()

            let task = makeFetchTask(debounce: nil) { try await $0.frontPage(0) }
            tasks[.feed] = task
            do {
                let page = try await task.value
                for story in page.stories { state.stories[story.id] = story }
                let ids = page.stories.map(\.id)
                state.feedLoaded = LoadedStories(
                    ids: ids, page: 0, totalPages: page.totalPages, loadedAt: now()
                )
                state.feedInitialStatus.finishSuccess()
            } catch is CancellationError {
                // Newer fetch will clear loading when it commits.
            } catch {
                state.feedInitialStatus.finishFailure(error.localizedDescription)
            }

        case .loadMore where state.searchQuery.isEmpty:
            guard let loaded = state.feedLoaded, loaded.hasMore,
                  !state.feedLoadMoreStatus.isLoading else { return }
            let next = loaded.nextPage
            state.feedLoadMoreStatus.startLoading()

            let task = makeFetchTask(debounce: nil) { try await $0.frontPage(next) }
            tasks[.feedMore] = task
            do {
                let page = try await task.value
                for story in page.stories { state.stories[story.id] = story }
                let ids = page.stories.map(\.id)
                state.feedLoaded?.appendPage(ids, totalPages: page.totalPages)
                state.feedLoadMoreStatus.finishSuccess()
            } catch is CancellationError {
            } catch {
                state.feedLoadMoreStatus.finishFailure(error.localizedDescription)
            }

        case .loadMore:
            guard let loaded = state.searchLoaded, loaded.hasMore,
                  !state.searchLoadMoreStatus.isLoading else { return }
            let query = state.searchQuery
            let next = loaded.nextPage
            state.searchLoadMoreStatus.startLoading()

            let task = makeFetchTask(debounce: nil) { try await $0.search(query, next) }
            tasks[.searchMore] = task
            do {
                let page = try await task.value
                for story in page.stories { state.stories[story.id] = story }
                let ids = page.stories.map(\.id)
                state.searchLoaded?.appendPage(ids, totalPages: page.totalPages)
                state.searchLoadMoreStatus.finishSuccess()
            } catch is CancellationError {
            } catch {
                state.searchLoadMoreStatus.finishFailure(error.localizedDescription)
            }
        }
    }

    /// Test-only teardown — the production `appCore` is app-lifetime
    /// (constructed lazily in `Core.swift`). Without this, the
    /// TaskRegistry → listener-Task → self cycle keeps the actor
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
