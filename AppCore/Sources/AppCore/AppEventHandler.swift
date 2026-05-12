import AsyncAlgorithms
import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Orchestration body for `AppModel`. Owns the in-flight task registry,
/// the `commands` stream, the search results channel, and every method
/// that mutates `AppState` in response to events. `AppModel` is a thin
/// bridge shell around this type — it holds `state` + re-exposes
/// `commands`, and forwards `dispatch(_:)` / `run()` calls here.
///
/// Not bridged to Kotlin. SkipFuse sees only `AppModel`'s public surface.
final class AppEventHandler {
    let state: AppState
    private let client: HNClient

    /// `ContinuousClock()` in production; tests inject a `TestClock` so
    /// the 250 ms debounce doesn't translate into real-clock waiting.
    private let clock: any Clock<Duration>

    /// One-shot commands from the handler to the UI. Read from `AppModel`
    /// (which re-exposes this same stream value); yielded into via
    /// `commandsContinuation` from `openStory`. Symmetric counterpart to
    /// `handle(_:)`.
    let commands: AsyncStream<AppCommand>
    private let commandsContinuation: AsyncStream<AppCommand>.Continuation

    enum TaskID { case feed, feedMore, search, searchMore }
    private var tasks = TaskRegistry<TaskID>()

    /// Sendable channel from `scheduleSearchFetch`'s forwarding Task to
    /// the consumer half of `run()`, which applies the result on the
    /// caller's actor. The pipeline's pump-into-merged-stream pattern
    /// must stay non-blocking — committing inline would require either
    /// an `await` (which sequentialises the watcher) or a Task that
    /// captures non-Sendable `state`.
    let searchResults: AsyncStream<SearchFetchOutcome>
    private let searchResultsContinuation: AsyncStream<SearchFetchOutcome>.Continuation

    /// Debounce window between a `state.searchQuery` write and the
    /// resulting fetch. Static so tests can name the same duration when
    /// advancing their `TestClock`.
    static let searchDebounce: Duration = .milliseconds(250)

    /// Outcome of a scheduled search fetch.
    enum SearchFetchOutcome: Sendable {
        case success(HNPage)
        case failure(String)
        case cancelled
    }

    init(
        state: AppState,
        client: HNClient,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.state = state
        self.client = client
        self.clock = clock
        let (commandsStream, commandsCont) = AsyncStream<AppCommand>.makeStream()
        self.commands = commandsStream
        self.commandsContinuation = commandsCont
        let (results, resultsCont) = AsyncStream<SearchFetchOutcome>.makeStream()
        self.searchResults = results
        self.searchResultsContinuation = resultsCont
    }

    /// Single entry point for every user-driven mutation. `async` so
    /// callers that need completion (e.g. SwiftUI's `.refreshable`) can
    /// `await` the call. `.refresh` and `.loadMore` both branch on
    /// `searchQuery` — empty → feed surface, non-empty → search.
    func handle(_ event: AppEvent) async {
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

    /// Long-lived pipeline that drives the app's background reactivity:
    /// merges `state.searchQueryChanges` (writes-to-fetch) and the
    /// `searchResults` channel (fetched-to-apply) into a single
    /// `for await` loop. The host `await`s this from `RootView`'s
    /// `.task` on iOS or `LaunchedEffect` on Android. Cancellation
    /// propagates from the host's surrounding Task.
    ///
    /// **Non-blocking schedule on the query side** — `scheduleSearchFetch`
    /// returns immediately so each new query cancel-and-replaces the
    /// prior in-flight fetch via the registry. The fetch's result lands
    /// here via the merged stream and is applied on the host's actor.
    ///
    /// `merge` consumes the two upstreams on internal child tasks; the
    /// outer `for await` runs on the caller's actor (SE-0461) so writes
    /// to `state` happen on the same actor as the host's reads.
    func run() async {
        enum PipelineEvent: Sendable { case query(String), outcome(SearchFetchOutcome) }

        let queries = state.searchQueryChanges.map(PipelineEvent.query)
        let outcomes = searchResults.map(PipelineEvent.outcome)

        for await event in merge(queries, outcomes) {
            switch event {
            case .query(let q) where q.isEmpty:
                clearSearch()
            case .query(let q):
                scheduleSearchFetch(query: q, debounce: Self.searchDebounce)
            case .outcome(.success(let page)):
                for hit in page.hits { state.hits[hit.id] = hit }
                state.search.receiveInitialPage(page.hits.map(\.id), totalPages: page.totalPages)
            case .outcome(.failure(let message)):
                state.search.initialStatus.finishFailure(message)
            case .outcome(.cancelled):
                // Newer fetch will clear loading when it commits.
                break
            }
        }
    }

    /// Empty-query path of the pipeline, factored out so tests can drive
    /// it without spinning the full `run()` task. Replaces the entire
    /// search section in one write — drops the snapshot, resets both
    /// status axes, and cancels any in-flight search tasks.
    func clearSearch() {
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

    func runFeedFetch(debounce: Duration? = nil) async {
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

    func runFeedLoadMore() async {
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

    func runSearchFetch(query: String, debounce: Duration? = nil) async {
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

    func runSearchLoadMore() async {
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

    /// Schedules a debounced search fetch without blocking the caller.
    /// Used by the query-side of `run()` — its `for await` loop must
    /// keep reading new queries while the prior one is debouncing.
    ///
    /// **Fire-and-forget cancellation**: the inner network Task is
    /// stored in `tasks[.search]`; assigning a new one cancels the
    /// prior, which the trailing forwarding `Task` sees as
    /// `CancellationError` and reports as `.cancelled` for the consumer
    /// to no-op.
    ///
    /// **Why the forwarding Task**: we can't `await task.value` and
    /// commit inline from the pipeline (would re-introduce the blocking
    /// bug) and we can't capture `state`/`self` in the network Task
    /// (non-Sendable). The forwarding Task captures only the network
    /// `Task` and the result continuation (both Sendable) and forwards
    /// the outcome through `searchResults` to the consumer, which
    /// commits on the caller's actor.
    private func scheduleSearchFetch(query: String, debounce: Duration) {
        tasks[.searchMore] = nil
        state.search.loadMoreStatus = LoadStatus()
        state.search.initialStatus.startLoading()

        let task = makeFetchTask(debounce: debounce) { try await $0.search(query, 0) }
        tasks[.search] = task

        let resultsCont = searchResultsContinuation
        // Forwarding Task: awaits the network task and forwards the
        // outcome. Captures only `task` (Sendable; HNPage is Sendable)
        // and `resultsCont` (Sendable). No self, no state.
        Task {
            do {
                let page = try await task.value
                resultsCont.yield(.success(page))
            } catch is CancellationError {
                resultsCont.yield(.cancelled)
            } catch {
                resultsCont.yield(.failure(error.localizedDescription))
            }
        }
    }

    /// Build a fetch task that sleeps for `debounce` (if set), then runs
    /// `body`. The Task body captures only Sendable values (`client`,
    /// `clock`) — never `self`, never `state`. Caller `await`s
    /// `task.value` on its own actor and commits the result there.
    ///
    /// **`try` (not `try?`) on the sleep is load-bearing.** A test-mock
    /// closure that doesn't honor cancellation would otherwise fall
    /// through to the network call and commit stale data; the throw
    /// propagating is what makes cancel-and-replace robust against any
    /// client implementation.
    ///
    /// **`URLError(.cancelled)` is normalised to `CancellationError`.**
    /// `URLSession` surfaces task cancellation as `URLError.cancelled`,
    /// which would otherwise be reported as a transient error in the
    /// caller's catch arm rather than a silent supersede.
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

    /// Starts a fetch, awaits its result on the caller's actor, and
    /// commits inline. Used by `handle(.refresh)` / `.loadMore` and the
    /// four `run*Fetch` async methods.
    ///
    /// **Cancellation leaves `statusPath` asserted** — a newer fetch is
    /// responsible for clearing it when it commits. The
    /// `CancellationError` arm doesn't write `finishFailure`, so the
    /// spinner stays visible across cancel-and-replace.
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
            let page = try await task.value
            for hit in page.hits { state.hits[hit.id] = hit }
            onSuccess(state, page)
        } catch is CancellationError {
            // Newer fetch will clear loading when it commits.
        } catch {
            state[keyPath: statusPath].finishFailure(error.localizedDescription)
        }
    }
}
