import Foundation
import Observation
import HackerNews
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Workhorse for `UICore`. Non-`Sendable` `final class`.
///
/// `init` takes a `borrowing isolation: any Actor` parameter — caller
/// passes whichever actor's executor the long-running Tasks should run
/// on (MainActor in production via UICore; a `BorrowedExecutor` actor
/// under TestCore). Internally, an `IsolationSpawner` actor is built
/// whose `unownedExecutor` returns that actor's executor (SE-0392),
/// and every `spawnTask { … }` call routes its body through
/// `spawner.run { … }`. The actor-method-call hop reliably lands on
/// the borrowed executor, closing the SE-0420 propagation gap that
/// breaks `@isolated(any)`-based inheritance through `Task` literals.
/// See `skip-spike/REPRO.md`.
///
/// Async event-handling methods (`sendEvent`, `scheduleSearchFetch`)
/// still take `isolation: isolated (any Actor)? = #isolation` so calls
/// from the borrowed executor stay on it without an extra hop.
///
/// Not bridged to Kotlin; `UICore` re-exposes the public surface.
final class AppCore {
    let state: AppState

    private let commandsContinuation: AsyncStream<AppCommand>.Continuation
    let commands: AsyncStream<AppCommand>
    private let client: Client
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let spawner: IsolationSpawner

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
        let spawner = IsolationSpawner(borrowing: isolation)
        self.spawner = spawner

        // Listener for `state.searchQuery` writes (iOS @Bindable,
        // Android textFieldState collector). Empty → clear the search
        // surface and cancel anything in flight. Non-empty → schedule
        // a debounced fetch fire-and-forget: the body must return to
        // `for await` before the network call completes so the *next*
        // keystroke can cancel-and-replace the parked task.
        tasks[.searchListener] = spawnTask { core in
            for await query in core.state.searchQueryChanges {
                if query.isEmpty {
                    core.tasks[.search] = nil
                    core.tasks[.searchCommit] = nil
                    core.tasks[.searchMore] = nil
                    core.state.search = LoadableStories()
                } else {
                    core.scheduleSearchFetch(query: query)
                }
            }
        }
    }

    /// Spawn a Task whose body runs on the borrowed executor (=
    /// caller's actor at AppCore construction time). `body` receives
    /// `self` as the `core` parameter so call sites don't need an
    /// implicit `self` capture in the closure.
    fileprivate func spawnTask(
        _ body: sending @escaping (AppCore) async -> Void
    ) -> Task<Void, Never> {
        // `nonisolated(unsafe)` lets us forward the non-Sendable
        // `self` and the `sending` `body` into the Task closure.
        // Both are invoked exactly once, inside `spawner.run`, on
        // the borrowed executor.
        nonisolated(unsafe) let selfRef = self
        nonisolated(unsafe) let bodyRef = body
        let spawner = self.spawner
        return Task {
            await spawner.run { _ in
                await bodyRef(selfRef)
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

        tasks[.searchCommit] = spawnTask { core in
            do {
                let page = try await task.value
                try Task.checkCancellation()
                for story in page.stories { core.state.stories[story.id] = story }
                let ids = page.stories.map(\.id)
                core.state.search.receiveInitialPage(ids, totalPages: page.totalPages, loadedAt: core.now())
            } catch is CancellationError {
            } catch {
                core.state.search.initialStatus.finishFailure(error.localizedDescription)
            }
        }
    }

    /// Single entry point for every user-driven mutation. Each arm
    /// holds the entire flow for its event — the explicit
    /// feed/search and refresh/loadMore duplication is the point:
    /// each path reads top-to-bottom without jumping between helpers.
    func sendEvent(_ event: AppEvent, isolation: isolated (any Actor)? = #isolation) async {
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

/// Actor that borrows another actor's serial executor via SE-0392.
/// Calling `await spawner.run { _ in … }` from a nonisolated context
/// hops to the borrowed executor and runs the body there — the
/// runtime resolves the hop via `unownedExecutor` at call time, no
/// static type info required.
///
/// This sidesteps the SE-0420 → `@isolated(any)` propagation gap:
/// closure literals don't statically inherit SE-0420 dynamic isolation
/// (so `Task { await body() }` lands the body off-actor), but a
/// method call on `IsolationSpawner` is a regular cross-actor call
/// that does hop. See `skip-spike/REPRO.md` for the full picture.
private actor IsolationSpawner {
    /// Strong reference — keeps the borrowed actor (and thus its
    /// executor) alive for as long as this spawner exists.
    nonisolated let borrowed: any Actor

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        borrowed.unownedExecutor
    }

    init(borrowing isolation: any Actor) {
        self.borrowed = isolation
    }

    func run<R: Sendable>(
        _ body: sending @Sendable (isolated IsolationSpawner) async -> R
    ) async -> R {
        await body(self)
    }
}
