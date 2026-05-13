import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// PROTOTYPE: Non-Sendable class with isolation-inheriting methods.
///
/// Instead of being a real `actor` with a borrowed executor + a
/// `StateAccess` shim, `AppCoreActor` is a plain `final class` (not
/// `Sendable`). All methods take `isolation: isolated (any Actor)?
/// = #isolation` (SE-0420), inheriting the caller's isolation
/// statically. From `@MainActor` `AppCore`, methods run on MainActor;
/// from a per-test `TestCore` actor, on that actor.
///
/// Because the class is non-Sendable, its instance lives in exactly
/// one isolation region at a time — the one in which it was
/// constructed. `state: AppState` is a direct stored property; no
/// shim, no `assumeIsolated`.
final class AppCoreActor {
    let state: AppState

    private let commandsContinuation: AsyncStream<AppCommand>.Continuation
    let commands: AsyncStream<AppCommand>
    private let client: HNClient
    private let clock: any Clock<Duration>

    enum TaskID { case feed, feedMore, search, searchMore, searchListener }
    private var tasks = TaskRegistry<TaskID>()

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

    /// Direct state access — no shim. Reads any property of `AppState`
    /// directly because the function inherits the caller's isolation.
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
            break // omitted in prototype
        }
    }

    /// Synchronous mutation — no `state { … }` block, no `assumeIsolated`.
    func clearSearch(isolation: isolated (any Actor)? = #isolation) {
        tasks[.search] = nil
        tasks[.searchMore] = nil
        state.search = LoadableHits()
    }

    private func toggleRead(_ id: String, isolation: isolated (any Actor)? = #isolation) {
        if state.readIds.contains(id) {
            state.readIds.remove(id)
        } else {
            state.readIds.insert(id)
        }
    }

    private func openStory(_ id: String, isolation: isolated (any Actor)? = #isolation) {
        guard let hit = state.hits[id] else { return }
        state.readIds.insert(id)
        if let url = hit.url {
            commandsContinuation.yield(.presentURL(value: url))
        }
    }

    // MARK: Fetch path — shape of async + Task spawning

    func runFeedFetch(isolation: isolated (any Actor)? = #isolation) async {
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
            // newer fetch will clear
        } catch {
            state.feed.initialStatus.finishFailure(error.localizedDescription)
        }
    }

    func runSearchFetch(query: String, debounce: Duration? = nil,
                        isolation: isolated (any Actor)? = #isolation) async {
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
        } catch {
            state.search.initialStatus.finishFailure(error.localizedDescription)
        }
    }

    /// Fetch task body captures only Sendable values (`client`, `clock`).
    /// The result `HNPage` is Sendable so it crosses back fine.
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

    /// Spawn the long-lived search-query listener pinned to the caller's
    /// isolation. The `pinnedTask` helper (SE-0431 `@isolated(any)`)
    /// records the caller's dynamic isolation into the closure value, so
    /// the inner `Task` hops to that isolation before running `body` —
    /// inside the closure, captured non-Sendable `self` and `state` are
    /// reached on the right actor with no `assumeIsolated` check.
    func bootstrap(isolation: isolated (any Actor)? = #isolation) {
        tasks[.searchListener] = pinnedTask { [self] in
            for await query in state.searchQueryChanges {
                if query.isEmpty {
                    clearSearch()
                } else {
                    await scheduleSearchFetch(query: query, debounce: Self.searchDebounce)
                }
            }
        }
    }

    private func scheduleSearchFetch(
        query: String,
        debounce: Duration,
        isolation: isolated (any Actor)? = #isolation
    ) async {
        // omitted in prototype — would mirror the runSearchFetch shape.
        _ = query; _ = debounce
    }

    func shutdown(isolation: isolated (any Actor)? = #isolation) {
        tasks.cancelAll()
    }
}

/// Spawn an unstructured `Task` whose body runs on the caller's
/// isolation. `@isolated(any)` (SE-0431) stores the caller's dynamic
/// isolation in the closure value; the inner `Task { await body() }`
/// hops to that isolation when invoking it. This lets the closure
/// body capture non-Sendable values (e.g. `self` on a non-Sendable
/// orchestrator class) and reach them safely — exactly the affordance
/// a real `actor` would give for free, but available to an
/// isolation-inheriting class.
func pinnedTask(
    isolation: isolated (any Actor)? = #isolation,
    _ body: sending @escaping @isolated(any) () async -> Void
) -> Task<Void, Never> {
    Task { await body() }
}
