import Foundation
import Observation
import HackerNews
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The surfaces the UI consumes — observable state, a one-shot
/// command stream, and an `Equatable` send-event capability.
// SKIP @bridgeMembers
@MainActor
public struct AppCoreHandle {
    public let state: AppState
    public let commands: AsyncStream<AppCommand>
    public let sendEvent: SendAppEvent
}

/// Builds the `AppCore` and returns the handle for the UI to
/// consume.
///
/// Call once at app scope — iOS holds it as `@State` on the `App`,
/// Android stashes it on `Application` in `onCreate` — and keep the
/// handle for the process lifetime.
///
/// - Returns: A handle bundling state, the command stream, and the
///   send-event capability.
// SKIP @bridge
@MainActor public func makeAppCore() -> AppCoreHandle {
    // Safe: AppCore borrows MainActor's executor and AppCoreHandle is
    // @MainActor, so AppState only ever lives on MainActor. Unchecked is
    // the local opt-out from `assumeIsolated`'s Sendable-return check.
    struct Unchecked<Value>: @unchecked Sendable {
        let value: Value; init(_ value: Value) { self.value = value }
    }

    let appCore = AppCore(
        state: AppState(),
        client: Client(),
        clock: ContinuousClock(),
        isolation: MainActor.shared
    )
    appCore.assumeIsolated { $0.bind() }

    var appState: AppState { appCore.assumeIsolated { Unchecked($0.state) }.value }

    return AppCoreHandle(
        state: appState,
        commands: appCore.commands,
        sendEvent: SendAppEvent(appCore)
    )
}

/// Event-handling workhorse — the internal coordinator behind
/// ``AppCoreHandle``.
///
/// Borrows the host's `unownedExecutor`, so all methods and Tasks
/// run in the host's isolation region — `MainActor` in production,
/// a per-test `TestActor` in tests. ``AppState`` is non-`Sendable`
/// but is only ever touched on this borrowed executor.
///
/// - Note: Long-running listener Tasks are bootstrapped externally
///   via `bind()` after `init` returns — `makeAppCore` reaches it
///   sync via `assumeIsolated`; tests `await` it through the actor
///   hop. Keeping the bootstrap out of `init` avoids the "Task
///   spawned in a sync init body doesn't inherit actor isolation"
///   workaround.
actor AppCore {
    let state: AppState

    nonisolated let commands: AsyncStream<AppCommand>
    private let commandsContinuation: AsyncStream<AppCommand>.Continuation
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

    /// Debounce window between a `state.searchQuery` write and the
    /// resulting fetch.
    static let searchDebounce: Duration = .milliseconds(250)

    init(
        state: AppState,
        client: Client,
        clock: any Clock<Duration>,
        now: @escaping @Sendable () -> Date = Date.init,
        isolation: any Actor
    ) {
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.state = state
        self.commands = stream
        self.commandsContinuation = continuation
        self.client = client
        self.clock = clock
        self.now = now
        self.isolation = isolation
    }

    /// Binds long-running listener Tasks to `AppState`'s change streams.
    ///
    /// Call once per `AppCore`: from `makeAppCore` (sync, via
    /// `assumeIsolated`) in production, from `withAppCore` (async hop)
    /// in tests.
    ///
    /// - Note: `Task { … }` here inherits the actor's isolation via
    ///   `@_inheritActorContext` on `Task.init`, so `tasks[…]` /
    ///   `state.…` writes inside the spawned bodies stay isolated to
    ///   `self`.
    func bind() {
        tasks[.searchListener] = Task {
            for await query in state.searchQueryChanges {
                if query.isEmpty {
                    tasks[.search] = nil
                    tasks[.searchMore] = nil
                    state.searchLoaded = nil
                    state.searchInitialStatus = LoadStatus()
                    state.searchLoadMoreStatus = LoadStatus()
                    continue
                }

                tasks[.searchMore] = nil
                // @Observable re-fires notifications on equal writes;
                // skip the no-op writes to avoid per-character
                // recomposition during keystroke bursts.
                if state.searchLoadMoreStatus != LoadStatus() {
                    state.searchLoadMoreStatus = LoadStatus()
                }
                if !state.searchInitialStatus.isLoading {
                    state.searchInitialStatus.startLoading()
                }

                tasks[.search] = Task {
                    do {
                        let page = try await fetch(debounce: Self.searchDebounce) {
                            try await $0.search(query, 0)
                        }
                        try Task.checkCancellation()
                        for story in page.stories { state.stories[story.id] = story }
                        let ids = page.stories.map(\.id)
                        state.searchLoaded = LoadedStories(
                            ids: ids, page: 0, totalPages: page.totalPages, loadedAt: now()
                        )
                        state.searchInitialStatus.finishSuccess()
                    } catch is CancellationError {
                    } catch {
                        state.searchInitialStatus.finishFailure(error.localizedDescription)
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
    /// - Parameter event: The event to dispatch.
    func sendEvent(_ event: AppEvent) async {
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

        case .refresh:
            // Pull-to-refresh only; not reachable while search is active.
            // Cancel any in-flight load-more so its appended page doesn't
            // land on the snapshot we're about to replace.
            tasks[.feedMore] = nil
            state.feedLoadMoreStatus = LoadStatus()
            state.feedInitialStatus.startLoading()

            let task = Task {
                do {
                    let page = try await fetch(debounce: nil) { try await $0.frontPage(0) }
                    try Task.checkCancellation()
                    for story in page.stories { state.stories[story.id] = story }
                    let ids = page.stories.map(\.id)
                    state.feedLoaded = LoadedStories(
                        ids: ids, page: 0, totalPages: page.totalPages, loadedAt: now()
                    )
                    state.feedInitialStatus.finishSuccess()
                } catch is CancellationError {
                    // Newer fetch will clear loading when it commits.
                } catch {
                    state.feedInitialStatus.finishFailure(error.localizedDescription)
                }
            }
            tasks[.feed] = task
            await task.value

        case .loadMore where state.searchQuery.isEmpty:
            guard let loaded = state.feedLoaded, loaded.hasMore,
                  !state.feedLoadMoreStatus.isLoading else { return }
            let next = loaded.nextPage
            state.feedLoadMoreStatus.startLoading()

            let task = Task {
                do {
                    let page = try await fetch(debounce: nil) { try await $0.frontPage(next) }
                    try Task.checkCancellation()
                    for story in page.stories { state.stories[story.id] = story }
                    let ids = page.stories.map(\.id)
                    state.feedLoaded?.appendPage(ids, totalPages: page.totalPages)
                    state.feedLoadMoreStatus.finishSuccess()
                } catch is CancellationError {
                } catch {
                    state.feedLoadMoreStatus.finishFailure(error.localizedDescription)
                }
            }
            tasks[.feedMore] = task
            await task.value

        case .loadMore:
            guard let loaded = state.searchLoaded, loaded.hasMore,
                  !state.searchLoadMoreStatus.isLoading else { return }
            let query = state.searchQuery
            let next = loaded.nextPage
            state.searchLoadMoreStatus.startLoading()

            let task = Task {
                do {
                    let page = try await fetch(debounce: nil) { try await $0.search(query, next) }
                    try Task.checkCancellation()
                    for story in page.stories { state.stories[story.id] = story }
                    let ids = page.stories.map(\.id)
                    state.searchLoaded?.appendPage(ids, totalPages: page.totalPages)
                    state.searchLoadMoreStatus.finishSuccess()
                } catch is CancellationError {
                } catch {
                    state.searchLoadMoreStatus.finishFailure(error.localizedDescription)
                }
            }
            tasks[.searchMore] = task
            await task.value
        }
    }

    /// Test-only teardown — cancels in-flight Tasks so the actor
    /// doesn't outlive its test.
    ///
    /// - Note: Without this, the `TaskRegistry` → listener-Task →
    ///   `self` cycle keeps the actor alive past test scope.
    func shutdown() {
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
