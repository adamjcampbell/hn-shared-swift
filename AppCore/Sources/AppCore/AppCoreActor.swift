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

    /// PROTOTYPE OPEN QUESTION — long-lived listener Task that captures
    /// `self` (non-Sendable). Two candidate shapes:
    ///
    ///   (a) `Task { [self, isolation] in
    ///           guard let iso = isolation else { return }
    ///           for await query in state.searchQueryChanges {
    ///               iso.assumeIsolated { _ in self.handle(query) }
    ///           }
    ///       }`
    ///       — one runtime `assumeIsolated` check per event; iso captured
    ///       as `(any Actor)?` which is Sendable.
    ///
    ///   (b) `Task { @MainActor [self] in … }` — only works because
    ///       production isolation *is* MainActor. Tests pin to a per-test
    ///       actor instead, so (b) doesn't generalise.
    ///
    /// Either way the Task can't capture non-Sendable `self` without
    /// some isolation pin. In the current `actor` design, `self` is
    /// Sendable so the capture is free — this is the one ergonomic
    /// cost of dropping the shim.
    func bootstrap(isolation: isolated (any Actor)? = #isolation) {
        // shape (a) — left commented; see runFeedFetch above for the
        // direct-state-access shape that's the win we care about.
    }

    func shutdown(isolation: isolated (any Actor)? = #isolation) {
        tasks.cancelAll()
    }
}
