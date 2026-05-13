import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Internal orchestrator for `AppCore`. Owns `AppState`, the
/// commands continuation, the in-flight task registry, and every
/// method that mutates `AppState`.
///
/// `@MainActor`-pinned for production. The original plan called for a
/// nested `actor` whose `unownedExecutor` was borrowed from an
/// `isolation: any Actor` init parameter (Point-Free CA 2.0 / Video
/// #363 "Actor Reentrancy" pattern), so a test wrapper could pass its
/// own per-instance actor and unlock parallel test execution. That
/// shape was blocked by region-based isolation: passing
/// non-`Sendable` `AppState` between the wrapper's region and the
/// inner actor's region fails both `assumeIsolated` (Sendable return
/// constraint) and `nonisolated let` (Sendable type constraint).
/// Skipping `AppState`'s Sendability with `@unchecked Sendable` is
/// rejected by project policy. We therefore keep `AppCoreActor` as a
/// `@MainActor final class` — the rename and dissolution land; the
/// per-test custom-actor variant is deferred behind a future test
/// helper that mediates state reads through async hops.
///
/// Not bridged to Kotlin. `AppCore` re-exposes the public surface.
@MainActor
final class AppCoreActor {
    let state: AppState
    let commands: AsyncStream<AppCommand>
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
    static let searchDebounce: Duration = .milliseconds(250)

    init(
        client: HNClient = HNClient(),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.state = AppState()
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.commands = stream
        self.commandsContinuation = continuation
        self.client = client
        self.clock = clock
    }

    /// Single entry point for every user-driven mutation.
    func dispatch(_ event: AppEvent) async {
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

    /// Long-lived consumer of `state.searchQueryChanges`. The host
    /// `await`s `AppCore.run()` from `RootView`'s `.task` on iOS or
    /// `LaunchedEffect` on Android; that call delegates here.
    ///
    /// Each new query cancel-and-replaces the prior in-flight fetch
    /// via the registry; the fetch result commits inside the
    /// unstructured Task spawned by `scheduleSearchFetch`, which
    /// inherits this actor's executor.
    func run() async {
        for await query in state.searchQueryChanges {
            if query.isEmpty {
                clearSearch()
            } else {
                await scheduleSearchFetch(query: query, debounce: Self.searchDebounce)
            }
        }
    }

    /// Replace the entire search section atomically: cancel any
    /// in-flight search tasks and drop the snapshot in one write so
    /// the projection never observes a partially-cleared state.
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

    func runFeedFetch() async {
        // Refresh supersedes any in-flight load-more: cancel its task
        // (otherwise its appended page would land on the snapshot we're
        // about to replace) and reset its status (otherwise the stale
        // spinner/error would outlive the refresh).
        tasks[.feedMore] = nil
        state.feed.loadMoreStatus = LoadStatus()
        await runFetch(
            id: .feed,
            statusPath: \.feed.initialStatus,
            debounce: nil,
            body: { try await $0.frontPage(0) },
            onSuccess: { state, ids, page in
                state.feed.receiveInitialPage(ids, totalPages: page.totalPages)
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
            onSuccess: { state, ids, page in
                state.feed.receiveLoadMorePage(ids, totalPages: page.totalPages)
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
            onSuccess: { state, ids, page in
                state.search.receiveInitialPage(ids, totalPages: page.totalPages)
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
            onSuccess: { state, ids, page in
                state.search.receiveLoadMorePage(ids, totalPages: page.totalPages)
            }
        )
    }

    /// Schedules a debounced search fetch without blocking the caller.
    ///
    /// **Fire-and-forget cancellation**: the inner network Task is
    /// stored in `tasks[.search]`; assigning a new one cancels the
    /// prior. The trailing `Task { [self] in … }` awaiting `task.value`
    /// catches `CancellationError` and no-ops — a newer fetch is
    /// responsible for clearing the loading status when it commits.
    ///
    /// `self` is an actor reference (Sendable), so the Task captures
    /// it directly and commits the result on this actor's executor —
    /// no forwarding channel required.
    private func scheduleSearchFetch(query: String, debounce: Duration) async {
        tasks[.searchMore] = nil
        state.search.loadMoreStatus = LoadStatus()
        state.search.initialStatus.startLoading()

        let task = makeFetchTask(debounce: debounce) { try await $0.search(query, 0) }
        tasks[.search] = task

        Task { [self] in
            do {
                let page = try await task.value
                state.search.receiveInitialPage(state.upsert(page), totalPages: page.totalPages)
            } catch is CancellationError {
                // Newer fetch will clear loading when it commits.
            } catch {
                state.search.initialStatus.finishFailure(error.localizedDescription)
            }
        }
    }

    /// Build a fetch task that sleeps for `debounce` (if set), then runs
    /// `body`. Captures only Sendable values (`client`, `clock`).
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

    /// **Cancellation leaves `statusPath` asserted** — a newer fetch is
    /// responsible for clearing it when it commits. The
    /// `CancellationError` arm doesn't write `finishFailure`, so the
    /// spinner stays visible across cancel-and-replace.
    private func runFetch(
        id: TaskID,
        statusPath: ReferenceWritableKeyPath<AppState, LoadStatus>,
        debounce: Duration?,
        body: @Sendable @escaping (HNClient) async throws -> HNPage,
        onSuccess: (AppState, [String], HNPage) -> Void
    ) async {
        state[keyPath: statusPath].startLoading()
        let task = makeFetchTask(debounce: debounce, body: body)
        tasks[id] = task
        do {
            let page = try await task.value
            onSuccess(state, state.upsert(page), page)
        } catch is CancellationError {
            // Newer fetch will clear loading when it commits.
        } catch {
            state[keyPath: statusPath].finishFailure(error.localizedDescription)
        }
    }
}
