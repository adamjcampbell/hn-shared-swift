import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Internal orchestrator for `AppCore`. Real `actor` whose executor is
/// borrowed from `isolation: any Actor` via `unownedExecutor` (SE-0392).
/// Production passes `MainActor.shared`; tests pass a per-instance
/// `TestCore` actor.
///
/// `AppCoreActor` does **not** own `AppState` — the shell does. State
/// mutations are mediated by the `acquireState` closure that the shell
/// installs post-construction via `handler.assumeIsolated { handler in
/// handler.acquireState = ... }`. The closure body runs on the shell's
/// isolation (where `AppState` lives), so non-`Sendable` `AppState`
/// never crosses an actor boundary.
///
/// Reads use the captured-var `read<T>(_:)` helper, which routes
/// through `acquireState` synchronously.
///
/// Not bridged to Kotlin. `AppCore` re-exposes the public surface.
actor AppCoreActor {
    private let isolation: any Actor

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        isolation.unownedExecutor
    }

    /// Set by the shell post-init. When invoked, runs the mutation
    /// closure on the shell's isolation (which is also this actor's
    /// borrowed executor). Optional because there's a brief window
    /// between this actor's construction and the shell installing the
    /// closure; during that window, mutations are no-ops.
    var acquireState: (@Sendable (@Sendable (AppState) -> Void) -> Void)?

    private let commandsContinuation: AsyncStream<AppCommand>.Continuation

    /// The shell-side read end. Re-exposed by the shell as its public
    /// `commands` property. The shell must construct the (stream,
    /// continuation) pair externally and pass both in so the shell
    /// has the stream available *before* calling this init (it needs
    /// `commands` initialized before passing `self` as `isolation`).
    nonisolated let commands: AsyncStream<AppCommand>

    private let client: HNClient

    /// `ContinuousClock()` in production; tests inject a `TestClock`
    /// so the 250 ms debounce doesn't translate into real-clock
    /// waiting.
    private let clock: any Clock<Duration>

    enum TaskID { case feed, feedMore, search, searchMore }
    private var tasks = TaskRegistry<TaskID>()

    /// Debounce window between a `state.searchQuery` write and the
    /// resulting fetch. Static so tests can name the same duration
    /// when advancing their `TestClock`.
    static let searchDebounce: Duration = .milliseconds(250)

    init(
        isolation: any Actor,
        commands: AsyncStream<AppCommand>,
        commandsContinuation: AsyncStream<AppCommand>.Continuation,
        client: HNClient = HNClient(),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.isolation = isolation
        self.commands = commands
        self.commandsContinuation = commandsContinuation
        self.client = client
        self.clock = clock
    }

    // MARK: - Public dispatch surface

    /// Single entry point for every user-driven mutation.
    func dispatch(_ event: AppEvent) async {
        switch event {
        case .toggleRead(let id):
            toggleRead(id)
        case .openStory(let id):
            openStory(id)
        case .refresh:
            if read({ $0.searchQuery.isEmpty }) {
                await runFeedFetch()
            } else {
                let query = read { $0.searchQuery }
                await runSearchFetch(query: query)
            }
        case .loadMore:
            if read({ $0.searchQuery.isEmpty }) {
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
    /// inherits this actor's executor (= shell's).
    func run() async {
        let stream = read { $0.searchQueryChanges }
        for await query in stream {
            if query.isEmpty {
                clearSearch()
            } else {
                await scheduleSearchFetch(query: query, debounce: Self.searchDebounce)
            }
        }
    }

    // MARK: - State access helpers

    /// Read any value from AppState via the shell's isolation.
    /// Synchronous — `acquireState` runs its closure inline, so by the
    /// time this returns the box's value is set.
    ///
    /// `@Sendable` closures can't mutate captured `var`s, so we use a
    /// reference-typed box. The box is only ever touched synchronously
    /// inside the closure body, so `@unchecked Sendable` is sound.
    ///
    /// Force-unwraps the box: if `acquireState` is nil (shell hasn't
    /// installed yet), this crashes — a programmer error visible
    /// immediately in tests. Production `AppCore` installs
    /// `acquireState` synchronously in init, so the window can't be
    /// observed.
    private func read<T>(_ work: @Sendable (AppState) -> T) -> T {
        let box = ReadBox<T>()
        acquireState?({ state in
            box.value = work(state)
        })
        return box.value!
    }

    // MARK: - Synchronous mutations

    /// Replace the entire search section atomically: cancel any
    /// in-flight search tasks and drop the snapshot in one write so
    /// the projection never observes a partially-cleared state.
    func clearSearch() {
        tasks[.search] = nil
        tasks[.searchMore] = nil
        acquireState?({ state in
            state.search = LoadableHits()
        })
    }

    private func toggleRead(_ id: String) {
        acquireState?({ state in
            if state.readIds.contains(id) {
                state.readIds.remove(id)
            } else {
                state.readIds.insert(id)
            }
        })
    }

    /// Mark a known story as read and, if it has a URL, ask the UI to
    /// present it. Single dictionary lookup against the entity store —
    /// no per-projection scan. Unknown ids are a no-op (no readIds
    /// insert, no command yielded).
    private func openStory(_ id: String) {
        struct Lookup { let exists: Bool; let url: String? }
        let lookup = read { state -> Lookup in
            guard let hit = state.hits[id] else { return Lookup(exists: false, url: nil) }
            return Lookup(exists: true, url: hit.url)
        }
        guard lookup.exists else { return }
        acquireState?({ state in
            state.readIds.insert(id)
        })
        if let url = lookup.url {
            commandsContinuation.yield(.presentURL(value: url))
        }
    }

    // MARK: - Fetch orchestration

    func runFeedFetch() async {
        // Refresh supersedes any in-flight load-more: cancel its task
        // (otherwise its appended page would land on the snapshot
        // we're about to replace) and reset its status (otherwise
        // the stale spinner/error would outlive the refresh).
        tasks[.feedMore] = nil
        acquireState?({ state in
            state.feed.loadMoreStatus = LoadStatus()
            state.feed.initialStatus.startLoading()
        })
        do {
            let page = try await runFetchTask(id: .feed, debounce: nil) { client in
                try await client.frontPage(0)
            }
            acquireState?({ state in
                let ids = state.upsert(page)
                state.feed.receiveInitialPage(ids, totalPages: page.totalPages)
            })
        } catch is CancellationError {
            // Newer fetch will clear loading when it commits.
        } catch {
            let message = error.localizedDescription
            acquireState?({ state in
                state.feed.initialStatus.finishFailure(message)
            })
        }
    }

    func runFeedLoadMore() async {
        let next: Int? = read { state in
            guard let loaded = state.feed.loadedHits, loaded.hasMore,
                  !state.feed.loadMoreStatus.isLoading else { return nil }
            return loaded.nextPage
        }
        guard let next else { return }

        acquireState?({ state in
            state.feed.loadMoreStatus.startLoading()
        })
        do {
            let page = try await runFetchTask(id: .feedMore, debounce: nil) { client in
                try await client.frontPage(next)
            }
            acquireState?({ state in
                let ids = state.upsert(page)
                state.feed.receiveLoadMorePage(ids, totalPages: page.totalPages)
            })
        } catch is CancellationError {
            // Newer fetch will clear loading when it commits.
        } catch {
            let message = error.localizedDescription
            acquireState?({ state in
                state.feed.loadMoreStatus.finishFailure(message)
            })
        }
    }

    func runSearchFetch(query: String, debounce: Duration? = nil) async {
        tasks[.searchMore] = nil
        acquireState?({ state in
            state.search.loadMoreStatus = LoadStatus()
            state.search.initialStatus.startLoading()
        })
        do {
            let page = try await runFetchTask(id: .search, debounce: debounce) { client in
                try await client.search(query, 0)
            }
            acquireState?({ state in
                let ids = state.upsert(page)
                state.search.receiveInitialPage(ids, totalPages: page.totalPages)
            })
        } catch is CancellationError {
            // Newer fetch will clear loading when it commits.
        } catch {
            let message = error.localizedDescription
            acquireState?({ state in
                state.search.initialStatus.finishFailure(message)
            })
        }
    }

    func runSearchLoadMore() async {
        struct LoadMoreParams { let query: String; let next: Int }
        let params: LoadMoreParams? = read { state in
            guard let loaded = state.search.loadedHits, loaded.hasMore,
                  !state.search.loadMoreStatus.isLoading else { return nil }
            return LoadMoreParams(query: state.searchQuery, next: loaded.nextPage)
        }
        guard let params else { return }

        acquireState?({ state in
            state.search.loadMoreStatus.startLoading()
        })
        do {
            let page = try await runFetchTask(id: .searchMore, debounce: nil) { client in
                try await client.search(params.query, params.next)
            }
            acquireState?({ state in
                let ids = state.upsert(page)
                state.search.receiveLoadMorePage(ids, totalPages: page.totalPages)
            })
        } catch is CancellationError {
            // Newer fetch will clear loading when it commits.
        } catch {
            let message = error.localizedDescription
            acquireState?({ state in
                state.search.loadMoreStatus.finishFailure(message)
            })
        }
    }

    /// Schedules a debounced search fetch without blocking the caller.
    ///
    /// **Fire-and-forget cancellation**: the inner network Task is
    /// stored in `tasks[.search]`; assigning a new one cancels the
    /// prior. The trailing `Task { [self] in … }` awaiting
    /// `task.value` catches `CancellationError` and no-ops — a newer
    /// fetch is responsible for clearing the loading status when it
    /// commits.
    ///
    /// `self` is `AppCoreActor` (Sendable since actor), so the Task
    /// captures it directly. The Task body inherits this actor's
    /// executor (= shell's), so `self.acquireState?(...)` calls run
    /// on the shell's isolation.
    private func scheduleSearchFetch(query: String, debounce: Duration) async {
        tasks[.searchMore] = nil
        acquireState?({ state in
            state.search.loadMoreStatus = LoadStatus()
            state.search.initialStatus.startLoading()
        })

        let task = makeFetchTask(debounce: debounce) { client in
            try await client.search(query, 0)
        }
        tasks[.search] = task

        Task { [self] in
            do {
                let page = try await task.value
                acquireState?({ state in
                    let ids = state.upsert(page)
                    state.search.receiveInitialPage(ids, totalPages: page.totalPages)
                })
            } catch is CancellationError {
                // Newer fetch will clear loading when it commits.
            } catch {
                let message = error.localizedDescription
                acquireState?({ state in
                    state.search.initialStatus.finishFailure(message)
                })
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
            do {
                return try await body(client)
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            }
        }
    }

    /// Spawns a fetch task, stores it in the registry (cancelling
    /// any prior with the same id), and awaits its value. Used by
    /// the awaiting paths (`runFeedFetch`, `runFeedLoadMore`,
    /// `runSearchFetch`, `runSearchLoadMore`).
    private func runFetchTask(
        id: TaskID,
        debounce: Duration?,
        body: @Sendable @escaping (HNClient) async throws -> HNPage
    ) async throws -> HNPage {
        let task = makeFetchTask(debounce: debounce, body: body)
        tasks[id] = task
        return try await task.value
    }
}

/// Synchronous capture holder for `AppCoreActor.read<T>(_:)`. The
/// closure that mutates `value` runs inline inside `acquireState`'s
/// synchronous body; no real cross-thread access happens.
private final class ReadBox<T>: @unchecked Sendable {
    var value: T?
}
