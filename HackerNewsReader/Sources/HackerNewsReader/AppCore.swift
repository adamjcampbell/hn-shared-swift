import Foundation
import Observation
import HackerNews
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Workhorse for `UICore`. Non-`Sendable` `final class`.
///
/// The host (`UICore` `@MainActor` struct in production, `TestCore`
/// actor in tests) supplies a `mutate` closure post-construction.
/// Long-running Tasks (the `searchQuery` listener, the post-fetch
/// search-commit) call `await self.mutate?({ … })` to hop to the
/// host's actor before touching `state` / `tasks`. Direct `sendEvent`
/// calls stay on the caller's actor via SE-0420 `isolation:` parameter.
///
/// `Mutate` is `@isolated(any)` so it can carry whichever actor's
/// isolation the host has (`@MainActor` or a custom test actor). The
/// `@_inheritActorContext` attribute on `setMutate(_:)` is what makes
/// the closure literal at the call site inherit the host's actor
/// isolation, and the closure body must include a sync-actor-method
/// call (`self.applyMutation(body)`) to force the inference. See
/// `skip-spike/REPRO.md` for the full picture.
///
/// Not bridged to Kotlin; `UICore` re-exposes the public surface.
final class AppCore {
    let state: AppState

    private let commandsContinuation: AsyncStream<AppCommand>.Continuation
    let commands: AsyncStream<AppCommand>
    private let client: Client
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date

    /// Closure that hops onto the host's actor and runs `body` there.
    /// `nil` until the host calls `setMutate(_:)`.
    typealias Mutate = @isolated(any) @Sendable (sending @escaping () -> Void) async -> Void
    private var mutate: Mutate?

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
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.state = state
        self.commands = commands
        self.commandsContinuation = commandsContinuation
        self.client = client
        self.clock = clock
        self.now = now
    }

    /// Host calls this once after construction to install the
    /// hop-to-host closure. `@_inheritActorContext` makes the closure
    /// literal at the call site inherit the host's actor; the
    /// recommended body shape is `{ body in self.applyMutation(body) }`
    /// where `applyMutation` is a sync actor-isolated method — the
    /// sync call forces actor-isolation inference, which
    /// `@isolated(any)` then captures as the runtime hop target.
    /// Installs the listener Task at the same time, so the host
    /// doesn't need a separate "start" call.
    func setMutate(@_inheritActorContext _ body: @escaping Mutate) {
        self.mutate = body
        startListener()
    }

    private func startListener() {
        // Listener Task itself is non-isolated; its `for await` on the
        // AsyncStream is nonisolated-friendly. Each yielded query is
        // handled via `mutate`, which hops to the host actor so
        // `tasks` / `state` mutations are serialised with `sendEvent`.
        nonisolated(unsafe) let selfRef = self
        tasks[.searchListener] = Task {
            for await query in selfRef.state.searchQueryChanges {
                await selfRef.mutate?({
                    if query.isEmpty {
                        selfRef.tasks[.search] = nil
                        selfRef.tasks[.searchCommit] = nil
                        selfRef.tasks[.searchMore] = nil
                        selfRef.state.search = LoadableStories()
                    } else {
                        selfRef.scheduleSearchFetch(query: query)
                    }
                })
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
    /// Called only from the listener body (already on host actor) and
    /// from `sendEvent` (`#isolation` puts us on the caller's actor),
    /// so all the synchronous mutations here are on the host actor.
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

        // Commit Task: starts non-isolated, awaits the network call,
        // then hops back via `mutate` to apply state mutations on host.
        nonisolated(unsafe) let selfRef = self
        tasks[.searchCommit] = Task {
            do {
                let page = try await task.value
                try Task.checkCancellation()
                await selfRef.mutate?({
                    for story in page.stories { selfRef.state.stories[story.id] = story }
                    let ids = page.stories.map(\.id)
                    selfRef.state.search.receiveInitialPage(ids, totalPages: page.totalPages, loadedAt: selfRef.now())
                })
            } catch is CancellationError {
            } catch {
                await selfRef.mutate?({
                    selfRef.state.search.initialStatus.finishFailure(error.localizedDescription)
                })
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
