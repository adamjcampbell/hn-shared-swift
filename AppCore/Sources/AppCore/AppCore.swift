import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Workhorse for `UICore`. Plain `final class` (not `Sendable`); all
/// methods take `isolation: isolated (any Actor)? = #isolation`
/// (SE-0420), inheriting the caller's isolation statically. From
/// `@MainActor` `UICore`, methods run on MainActor; from a per-test
/// `TestCore` actor, on that actor.
///
/// Because the class is non-Sendable, its instance lives in exactly
/// one isolation region at a time — the one in which it was
/// constructed. `state: AppState` is a direct stored property; no
/// shim, no `assumeIsolated`.
///
/// Internal sync mutation methods (`toggleRead`, `openStory`,
/// `clearSearch`) deliberately omit the `isolation` parameter — they
/// don't spawn Tasks and don't call other isolation-inheriting helpers
/// in a way that requires forwarding. Region isolation tracks `self`
/// through the caller's region and direct property access is fine.
/// Any method that spawns an `isolatedTask` (or calls something that
/// does) must keep the parameter so `#isolation` propagates through.
///
/// Not bridged to Kotlin. `UICore` re-exposes the public surface.
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
        clock: any Clock<Duration>
    ) {
        self.state = state
        self.commands = commands
        self.commandsContinuation = commandsContinuation
        self.client = client
        self.clock = clock
    }

    /// Post-construction setup the shell calls directly. Spawns the
    /// search-query listener via `isolatedTask` so the long-lived Task
    /// runs on the same isolation as the rest of the workhorse.
    func bootstrap(isolation: isolated (any Actor)? = #isolation) {
        tasks[.searchListener] = isolatedTask { [self] in
            for await query in state.searchQueryChanges {
                if query.isEmpty {
                    clearSearch()
                } else {
                    scheduleSearchFetch(query: query, debounce: Self.searchDebounce)
                }
            }
        }
    }

    // MARK: - Public dispatch surface

    /// Single entry point for every user-driven mutation.
    func dispatch(_ event: AppEvent, isolation: isolated (any Actor)? = #isolation) async {
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

    /// Test-only teardown — production `UICore` is app-lifetime.
    func shutdown() {
        tasks.cancelAll()
    }

    // MARK: - Synchronous mutations

    /// Replace the entire search section atomically: cancel any
    /// in-flight search tasks and drop the snapshot in one write so
    /// the projection never observes a partially-cleared state.
    func clearSearch() {
        tasks[.search] = nil
        tasks[.searchCommit] = nil
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
    /// no per-projection scan. Unknown ids are a no-op.
    private func openStory(_ id: String) {
        guard let hit = state.hits[id] else { return }
        state.readIds.insert(id)
        if let url = hit.url {
            commandsContinuation.yield(.presentURL(value: url))
        }
    }

    // MARK: - Fetch orchestration

    func runFeedFetch(isolation: isolated (any Actor)? = #isolation) async {
        // Refresh supersedes any in-flight load-more: cancel its task
        // (otherwise its appended page would land on the snapshot
        // we're about to replace) and reset its status (otherwise
        // the stale spinner/error would outlive the refresh).
        tasks[.feedMore] = nil
        state.feed.loadMoreStatus = LoadStatus()
        state.feed.initialStatus.startLoading()
        do {
            let page = try await runFetchTask(id: .feed, debounce: nil) { client in
                try await client.frontPage(0)
            }
            let ids = state.upsert(page)
            state.feed.receiveInitialPage(ids, totalPages: page.totalPages)
        } catch is CancellationError {
            // Newer fetch will clear loading when it commits.
        } catch {
            state.feed.initialStatus.finishFailure(error.localizedDescription)
        }
    }

    func runFeedLoadMore(isolation: isolated (any Actor)? = #isolation) async {
        guard let loaded = state.feed.loadedHits, loaded.hasMore,
              !state.feed.loadMoreStatus.isLoading else { return }
        let next = loaded.nextPage

        state.feed.loadMoreStatus.startLoading()
        do {
            let page = try await runFetchTask(id: .feedMore, debounce: nil) { client in
                try await client.frontPage(next)
            }
            let ids = state.upsert(page)
            state.feed.receiveLoadMorePage(ids, totalPages: page.totalPages)
        } catch is CancellationError {
            // Newer fetch will clear loading when it commits.
        } catch {
            state.feed.loadMoreStatus.finishFailure(error.localizedDescription)
        }
    }

    func runSearchFetch(
        query: String,
        debounce: Duration? = nil,
        isolation: isolated (any Actor)? = #isolation
    ) async {
        tasks[.searchMore] = nil
        state.search.loadMoreStatus = LoadStatus()
        state.search.initialStatus.startLoading()
        do {
            let page = try await runFetchTask(id: .search, debounce: debounce) { client in
                try await client.search(query, 0)
            }
            let ids = state.upsert(page)
            state.search.receiveInitialPage(ids, totalPages: page.totalPages)
        } catch is CancellationError {
            // Newer fetch will clear loading when it commits.
        } catch {
            state.search.initialStatus.finishFailure(error.localizedDescription)
        }
    }

    func runSearchLoadMore(isolation: isolated (any Actor)? = #isolation) async {
        guard let loaded = state.search.loadedHits, loaded.hasMore,
              !state.search.loadMoreStatus.isLoading else { return }
        let query = state.searchQuery
        let next = loaded.nextPage

        state.search.loadMoreStatus.startLoading()
        do {
            let page = try await runFetchTask(id: .searchMore, debounce: nil) { client in
                try await client.search(query, next)
            }
            let ids = state.upsert(page)
            state.search.receiveLoadMorePage(ids, totalPages: page.totalPages)
        } catch is CancellationError {
            // Newer fetch will clear loading when it commits.
        } catch {
            state.search.loadMoreStatus.finishFailure(error.localizedDescription)
        }
    }

    /// Fire-and-forget debounced search fetch. Parks the network call
    /// in `tasks[.search]` (cancellable via newer fetch or `clearSearch`)
    /// and the trailing commit awaiter in `tasks[.searchCommit]` so a
    /// backspace-to-empty mid-debounce can cancel both halves.
    private func scheduleSearchFetch(
        query: String,
        debounce: Duration,
        isolation: isolated (any Actor)? = #isolation
    ) {
        tasks[.searchMore] = nil
        // Skip the no-op write when the second/third keystroke arrives
        // while we're already loading — avoids re-firing `@Observable`
        // notifications (→ SwiftUI/Compose recomposition) per character.
        if state.search.loadMoreStatus != LoadStatus() {
            state.search.loadMoreStatus = LoadStatus()
        }
        if !state.search.initialStatus.isLoading {
            state.search.initialStatus.startLoading()
        }

        let task = makeFetchTask(debounce: debounce) { client in
            try await client.search(query, 0)
        }
        tasks[.search] = task

        // Registering the commit Task closes a race: if a `clearSearch`
        // lands between `task.value` resolving and the state write, the
        // commit would otherwise repopulate cleared state. The
        // post-await `checkCancellation` is what observes that cancel.
        tasks[.searchCommit] = isolatedTask { [self] in
            do {
                let page = try await task.value
                try Task.checkCancellation()
                let ids = state.upsert(page)
                state.search.receiveInitialPage(ids, totalPages: page.totalPages)
            } catch is CancellationError {
                // Newer fetch (or clearSearch) clears loading when it commits.
            } catch {
                state.search.initialStatus.finishFailure(error.localizedDescription)
            }
        }
    }

    /// Build a fetch task that sleeps for `debounce` (if set), then
    /// runs `body`. Captures only Sendable values (`client`, `clock`).
    ///
    /// **`try` (not `try?`) on the sleep is load-bearing.** A
    /// test-mock closure that doesn't honor cancellation would
    /// otherwise fall through to the network call and commit stale
    /// data; the throw propagating is what makes cancel-and-replace
    /// robust against any client implementation.
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
            // Cancellation may land between `sleep` returning and
            // `body` running — sleep's own check passed, then a fresh
            // `tasks[.search] = …` arrived. The post-sleep check
            // catches that window before we commit a stale page.
            try Task.checkCancellation()
            do {
                return try await body(client)
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            }
        }
    }

    /// Spawns a fetch task, stores it in the registry (cancelling any
    /// prior with the same id), and awaits its value. Used by awaiting
    /// paths (`runFeedFetch`, `runFeedLoadMore`, `runSearchFetch`,
    /// `runSearchLoadMore`).
    private func runFetchTask(
        id: TaskID,
        debounce: Duration?,
        body: @Sendable @escaping (HNClient) async throws -> HNPage,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> HNPage {
        let task = makeFetchTask(debounce: debounce, body: body)
        tasks[id] = task
        return try await task.value
    }
}

/// Spawn an unstructured `Task` whose body runs on the caller's
/// isolation. `@isolated(any)` (SE-0431) stores the caller's dynamic
/// isolation in the closure value; the inner `Task { await body() }`
/// hops to that isolation when invoking it. This lets the closure
/// body capture non-Sendable values (e.g. `self` on `AppCore`) and
/// reach them safely — exactly the affordance a real `actor` would
/// give for free, but available to an isolation-inheriting class.
///
/// The combination of attributes:
/// - `isolated (any Actor)? = #isolation` — captures the caller's
///   isolation at the call site (SE-0420).
/// - `@isolated(any)` — closure value carries that isolation; the
///   inner `Task` hops to it when calling `body()` (SE-0431).
/// - `sending` — the closure (which captures non-Sendable values) is
///   transferred to `isolatedTask`'s region rather than treated as
///   shared; combined with the hop-back-on-invoke, the caller can
///   keep using its captures safely (SE-0430).
func isolatedTask(
    isolation: isolated (any Actor)? = #isolation,
    _ body: sending @escaping @isolated(any) () async -> Void
) -> Task<Void, Never> {
    Task { await body() }
}
