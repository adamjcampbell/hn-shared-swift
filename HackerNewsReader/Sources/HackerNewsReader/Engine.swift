import Foundation
import HackerNews
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Message-handling workhorse — the internal coordinator behind
/// ``Core``.
///
/// Borrows the host's `unownedExecutor`, so all methods and Tasks
/// run in the host's isolation region — `MainActor` in production,
/// a per-test `TestActor` in tests. ``Model`` is non-`Sendable`
/// but is only ever touched on this borrowed executor.
///
/// - Note: Long-running listener Tasks are bootstrapped externally
///   via `bind()` after `init` returns — `makeCore` reaches it
///   sync via `assumeIsolated`; tests `await` it through the actor
///   hop.
actor Engine {
    let model: Model

    nonisolated let commands: AsyncStream<Command>
    private let commandsContinuation: AsyncStream<Command>.Continuation
    private let client: Client
    nonisolated let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    nonisolated let isolation: any Actor

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        isolation.unownedExecutor
    }

    enum TaskID { case feed, feedMore, search, searchMore, searchListener }
    typealias Tasks = TaskRegistry<TaskID>
    private var tasks = Tasks()

    /// Debounce window between a `model.searchQuery` write and the
    /// resulting fetch.
    static let searchDebounce: Duration = .milliseconds(250)

    init(
        model: Model = Model(),
        client: Client = Client(),
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = Date.init,
        isolation: any Actor
    ) {
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        self.model = model
        self.commands = stream
        self.commandsContinuation = continuation
        self.client = client
        self.clock = clock
        self.now = now
        self.isolation = isolation
    }

    /// Binds long-running listener Tasks to `Model`'s change streams.
    ///
    /// Call once per `Engine`: from `makeCore` (sync, via
    /// `assumeIsolated`) in production, from `withEngine` (async
    /// hop) in tests.
    ///
    /// - Note: `Task { … }` here inherits the actor's isolation via
    ///   `@_inheritActorContext` on `Task.init`, so `tasks[…]` /
    ///   `model.…` writes inside the spawned bodies stay isolated to
    ///   `self`.
    func bind() {
        tasks[.searchListener] = Task {
            for await query in model.searchQueryChanges {
                if query.isEmpty {
                    tasks[.search] = nil
                    tasks[.searchMore] = nil
                    model.searchLoaded = nil
                    model.searchInitialStatus = LoadStatus()
                    model.searchLoadMoreStatus = LoadStatus()
                    continue
                }

                tasks[.searchMore] = nil
                // @Observable re-fires notifications on equal writes;
                // skip the no-op writes to avoid per-character
                // recomposition during keystroke bursts.
                if model.searchLoadMoreStatus != LoadStatus() {
                    model.searchLoadMoreStatus = LoadStatus()
                }
                if !model.searchInitialStatus.isLoading {
                    model.searchInitialStatus.startLoading()
                }

                tasks[.search] = Task {
                    do {
                        let page = try await fetch(debounce: Self.searchDebounce) {
                            try await $0.search(query, 0)
                        }
                        try Task.checkCancellation()
                        for story in page.stories { model.stories[story.id] = story }
                        let ids = page.stories.map(\.id)
                        model.searchLoaded = LoadedStories(
                            ids: ids, page: 0, totalPages: page.totalPages, loadedAt: now()
                        )
                        model.searchInitialStatus.finishSuccess()
                    } catch is CancellationError {
                    } catch {
                        model.searchInitialStatus.finishFailure(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Single entry point for every user-driven mutation.
    ///
    /// Fetch arms await `task.value` so `.refreshable` holds the
    /// spinner until the fetch lands.
    ///
    /// - Parameter message: The message to dispatch.
    func sendMessage(_ message: Message) async {
        switch message {

        case .toggleRead(let id):
            if model.readIds.contains(id) {
                model.readIds.remove(id)
            } else {
                model.readIds.insert(id)
            }

        case .openStory(let id):
            guard let story = model.stories[id] else { return }
            model.readIds.insert(id)
            if let url = story.url {
                commandsContinuation.yield(.presentURL(value: url))
            }

        case .refresh:
            // Pull-to-refresh only; not reachable while search is active.
            // Cancel any in-flight load-more so its appended page doesn't
            // land on the snapshot we're about to replace.
            tasks[.feedMore] = nil
            model.feedLoadMoreStatus = LoadStatus()
            model.feedInitialStatus.startLoading()

            let task = Task {
                do {
                    let page = try await fetch(debounce: nil) { try await $0.frontPage(0) }
                    try Task.checkCancellation()
                    for story in page.stories { model.stories[story.id] = story }
                    let ids = page.stories.map(\.id)
                    model.feedLoaded = LoadedStories(
                        ids: ids, page: 0, totalPages: page.totalPages, loadedAt: now()
                    )
                    model.feedInitialStatus.finishSuccess()
                } catch is CancellationError {
                    // Newer fetch will clear loading when it commits.
                } catch {
                    model.feedInitialStatus.finishFailure(error.localizedDescription)
                }
            }
            tasks[.feed] = task
            await task.value

        case .loadMore where model.searchQuery.isEmpty:
            guard let loaded = model.feedLoaded, loaded.hasMore,
                  !model.feedLoadMoreStatus.isLoading else { return }
            let next = loaded.nextPage
            model.feedLoadMoreStatus.startLoading()

            let task = Task {
                do {
                    let page = try await fetch(debounce: nil) { try await $0.frontPage(next) }
                    try Task.checkCancellation()
                    for story in page.stories { model.stories[story.id] = story }
                    let ids = page.stories.map(\.id)
                    model.feedLoaded?.appendPage(ids, totalPages: page.totalPages)
                    model.feedLoadMoreStatus.finishSuccess()
                } catch is CancellationError {
                } catch {
                    model.feedLoadMoreStatus.finishFailure(error.localizedDescription)
                }
            }
            tasks[.feedMore] = task
            await task.value

        case .loadMore:
            guard let loaded = model.searchLoaded, loaded.hasMore,
                  !model.searchLoadMoreStatus.isLoading else { return }
            let query = model.searchQuery
            let next = loaded.nextPage
            model.searchLoadMoreStatus.startLoading()

            let task = Task {
                do {
                    let page = try await fetch(debounce: nil) { try await $0.search(query, next) }
                    try Task.checkCancellation()
                    for story in page.stories { model.stories[story.id] = story }
                    let ids = page.stories.map(\.id)
                    model.searchLoaded?.appendPage(ids, totalPages: page.totalPages)
                    model.searchLoadMoreStatus.finishSuccess()
                } catch is CancellationError {
                } catch {
                    model.searchLoadMoreStatus.finishFailure(error.localizedDescription)
                }
            }
            tasks[.searchMore] = task
            await task.value
        }
    }

    /// Cancels every Task this actor owns — the `bind()` listener
    /// plus any in-flight fetch.
    ///
    /// Test-only: production `Engine` is process-lifetime. Tests
    /// call this on fixture exit so the `TaskRegistry → Task → self`
    /// cycle releases and the actor doesn't outlive its test.
    func cancelAll() {
        tasks.cancelAll()
    }

    /// Sleeps for `debounce` (if set), then runs `body`.
    ///
    /// - Parameters:
    ///   - debounce: Delay before invoking `body`, or `nil` for none.
    ///   - body: Closure that issues the page fetch.
    /// - Returns: The page produced by `body`.
    /// - Throws: Whatever `body` throws, plus `CancellationError` if
    ///   the surrounding task is cancelled.
    /// - Note: `URLSession` surfaces task cancellation as
    ///   `URLError.cancelled`; this method rethrows it as
    ///   `CancellationError` so callers can match cancellation the
    ///   same way regardless of transport.
    private func fetch(
        debounce: Duration?,
        body: @Sendable (Client) async throws -> Page
    ) async throws -> Page {
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
