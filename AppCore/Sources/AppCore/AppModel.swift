import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Owns the app's `AppState` and the `dispatch(_:)` method that mutates
/// it in response to user events. Bridged to Kotlin via SkipFuse — see
/// the `// SKIP @bridge` markers below.
///
/// `AppState` is the `@Observable` reference; `AppModel` itself isn't
/// `@Observable` because its other fields (`client`, `clock`, in-flight
/// tasks, the commands continuation) aren't meant to be observed.
// SKIP @bridge
public final class AppModel {
    // SKIP @bridge
    public let state = AppState()

    /// One-shot commands from the model to the UI — the symmetric
    /// counterpart to `dispatch(_:)`. iOS subscribes with `for await`
    /// from a long-lived `.task`. On Android, Compose converts to
    /// `Flow` via SkipFuse's `KotlinConverting`.
    // SKIP @bridge
    public let commands: AsyncStream<AppCommand>

    private let commandsContinuation: AsyncStream<AppCommand>.Continuation
    private let client: HNClient

    /// `ContinuousClock()` in production; tests inject a `TestClock` so
    /// the 250 ms debounce doesn't translate into real-clock waiting.
    private let clock: any Clock<Duration>

    enum TaskID { case feed, feedMore, search, searchMore }
    private var tasks = TaskRegistry<TaskID>()

    /// Debounce window between a `state.searchQuery` write and the
    /// resulting fetch. Static so tests can name the same duration when
    /// advancing their `TestClock`.
    public static let searchDebounce: Duration = .milliseconds(250)

    // SKIP @bridge
    public init() {
        self.client = HNClient()
        self.clock = ContinuousClock()
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.commands = stream
        self.commandsContinuation = continuation
    }

    /// Test seam — not bridged. `client` and `clock` types don't bridge
    /// (closure-bag struct, existential `Clock`).
    public init(
        client: HNClient,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.client = client
        self.clock = clock
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.commands = stream
        self.commandsContinuation = continuation
    }

    /// Single entry point for every user-driven mutation. `async` so
    /// callers that need completion (e.g. SwiftUI's `.refreshable`) can
    /// `await` the call. `.refresh` and `.loadMore` both branch on
    /// `searchQuery` — empty → feed surface, non-empty → search.
    // SKIP @bridge
    public func dispatch(_ event: AppEvent) async {
        switch event {
        case .toggleRead(let id):
            toggleRead(id)
        case .openStory(let id):
            openStory(id)
        case .refresh:
            if state.searchQuery.isEmpty {
                await runFeedFetch()
            } else {
                await runSearchFetch(query: state.searchQuery)
            }
        case .loadMore:
            if state.searchQuery.isEmpty {
                await runFeedLoadMore()
            } else {
                await runSearchLoadMore()
            }
        }
    }

    /// Long-lived debounced-fetch loop on every `state.searchQuery`
    /// write. The host `await`s this from `RootView`'s `.task` on iOS
    /// or `LaunchedEffect` on Android. Cancellation propagates from
    /// the host's surrounding Task.
    ///
    /// Events come from `state.searchQueryChanges` — see that property
    /// for the `.bufferingNewest(1)` rationale (handles burst writes
    /// during a slow consumer). Empty query → `clearSearch()`; the
    /// feed stays cached so dismissing the search overlay restores it
    /// without a network call.
    // SKIP @bridge
    public func runSearchQueryWatcher() async {
        for await query in state.searchQueryChanges {
            if query.isEmpty {
                clearSearch()
            } else {
                await runSearchFetch(query: query, debounce: Self.searchDebounce)
            }
        }
    }

    /// Empty-query path of the watcher, factored out so tests can drive
    /// it without spinning the full watcher Task. Replaces the entire
    /// search section in one write — drops the snapshot, resets both
    /// status axes, and cancels any in-flight search tasks.
    public func clearSearch() {
        tasks[.search] = nil
        tasks[.searchMore] = nil
        state.search = LoadableHits()
    }

    private func toggleRead(_ id: String) {
        if state.readIds.contains(id) {
            state.readIds.remove(id)
        } else {
            state.readIds.insert(id)
        }
    }

    /// Mark a known story as read and, if it has a URL, ask the UI to
    /// present it. Single dictionary lookup against the entity store —
    /// no per-projection scan.
    private func openStory(_ id: String) {
        guard let hit = state.hits[id] else { return }
        state.readIds.insert(id)
        if let url = hit.url {
            commandsContinuation.yield(.presentURL(value: url))
        }
    }

    public func runFeedFetch(debounce: Duration? = nil) async {
        // Refresh supersedes any in-flight load-more: cancel its task
        // (otherwise its appended page would land on the snapshot we're
        // about to replace) and reset its status (otherwise the stale
        // spinner/error would outlive the refresh).
        tasks[.feedMore] = nil
        state.feed.loadMoreStatus = LoadStatus()
        await runFetch(
            id: .feed,
            statusPath: \.feed.initialStatus,
            debounce: debounce,
            body: { try await $0.frontPage(0) },
            onSuccess: { state, page in
                state.feed.receiveInitialPage(page.hits.map(\.id), totalPages: page.totalPages)
            }
        )
    }

    public func runFeedLoadMore() async {
        guard let loaded = state.feed.loadedHits, loaded.hasMore,
              !state.feed.loadMoreStatus.isLoading else { return }
        let next = loaded.nextPage
        await runFetch(
            id: .feedMore,
            statusPath: \.feed.loadMoreStatus,
            debounce: nil,
            body: { try await $0.frontPage(next) },
            onSuccess: { state, page in
                state.feed.receiveLoadMorePage(page.hits.map(\.id), totalPages: page.totalPages)
            }
        )
    }

    public func runSearchFetch(query: String, debounce: Duration? = nil) async {
        tasks[.searchMore] = nil
        state.search.loadMoreStatus = LoadStatus()
        await runFetch(
            id: .search,
            statusPath: \.search.initialStatus,
            debounce: debounce,
            body: { try await $0.search(query, 0) },
            onSuccess: { state, page in
                state.search.receiveInitialPage(page.hits.map(\.id), totalPages: page.totalPages)
            }
        )
    }

    public func runSearchLoadMore() async {
        guard let loaded = state.search.loadedHits, loaded.hasMore,
              !state.search.loadMoreStatus.isLoading else { return }
        let next = loaded.nextPage
        let query = state.searchQuery
        await runFetch(
            id: .searchMore,
            statusPath: \.search.loadMoreStatus,
            debounce: nil,
            body: { try await $0.search(query, next) },
            onSuccess: { state, page in
                state.search.receiveLoadMorePage(page.hits.map(\.id), totalPages: page.totalPages)
            }
        )
    }

    /// `awaitFetch` returning `nil` (superseded fetch) leaves the
    /// status flag asserted so the spinner stays visible across the
    /// cancel-and-replace.
    private func runFetch(
        id: TaskID,
        statusPath: ReferenceWritableKeyPath<AppState, LoadStatus>,
        debounce: Duration?,
        body: @Sendable @escaping (HNClient) async throws -> HNPage,
        onSuccess: (AppState, HNPage) -> Void
    ) async {
        state[keyPath: statusPath].startLoading()
        let task = makeFetchTask(debounce: debounce, body: body)
        tasks[id] = task
        do {
            guard let page = try await awaitFetch(task) else { return }
            onSuccess(state, page)
        } catch {
            state[keyPath: statusPath].finishFailure(error.localizedDescription)
        }
    }

    /// Build a fetch task that sleeps for `debounce` (if set), then runs
    /// `body`. The Task body captures only Sendable values (`client`,
    /// `clock`) — never `self`.
    ///
    /// **`try` (not `try?`) on the sleep is load-bearing.** A test-mock
    /// closure that doesn't honor cancellation would otherwise fall
    /// through to the network call and commit stale data; the throw
    /// propagating is what makes cancel-and-replace robust against any
    /// client implementation.
    ///
    /// **`URLError(.cancelled)` is normalised to `CancellationError`.**
    /// `URLSession` surfaces task cancellation as `URLError.cancelled`,
    /// which would otherwise hit the dispatch arm's generic `catch` and
    /// write a transient `*LoadError = "cancelled"`.
    private func makeFetchTask(
        debounce: Duration?,
        body: @Sendable @escaping (HNClient) async throws -> HNPage
    ) -> Task<HNPage, Error> {
        Task { [client, clock] in
            if let debounce {
                try await clock.sleep(for: debounce)
            }
            do {
                return try await body(client)
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            }
        }
    }

    /// Await `task`, upsert its hits into the entity store, and return
    /// the page. Returns `nil` if the task was cancelled — the caller
    /// short-circuits without touching its surface's state. Other
    /// errors propagate so the caller can record them.
    private func awaitFetch(_ task: Task<HNPage, Error>) async throws -> HNPage? {
        do {
            let page = try await task.value
            for hit in page.hits { state.hits[hit.id] = hit }
            return page
        } catch is CancellationError {
            return nil
        }
    }
}
