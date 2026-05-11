import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Owns the app's `AppState` and the `dispatch(_:)` method that mutates
/// it in response to user events. Bridged to Kotlin via SkipFuse — see
/// the `// SKIP @bridge` markers below.
///
/// `AppState` is the `@Observable` reference; `AppModel` itself isn't
/// `@Observable` because its other fields (`client`, `clock`, in-flight
/// tasks, the commands continuation) aren't meant to be observed.
// SKIP @bridge
public final class AppModel {
    // SKIP @bridge
    public let state = AppState()

    /// One-shot commands from the model to the UI — the symmetric
    /// counterpart to `dispatch(_:)`. iOS subscribes with `for await`
    /// from a long-lived `.task`. On Android, Compose converts to
    /// `Flow` via SkipFuse's `KotlinConverting`.
    // SKIP @bridge
    public let commands: AsyncStream<AppCommand>

    private let commandsContinuation: AsyncStream<AppCommand>.Continuation
    private let client: HNClient

    /// `ContinuousClock()` in production; tests inject a `TestClock` so
    /// the 250 ms debounce doesn't translate into real-clock waiting.
    private let clock: any Clock<Duration>

    enum TaskID { case feed, search }
    private var tasks = TaskRegistry<TaskID>()

    /// Debounce window between a `state.searchQuery` write and the
    /// resulting fetch. Static so tests can name the same duration when
    /// advancing their `TestClock`.
    public static let searchDebounce: Duration = .milliseconds(250)

    // SKIP @bridge
    public init() {
        self.client = HNClient()
        self.clock = ContinuousClock()
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.commands = stream
        self.commandsContinuation = continuation
    }

    /// Test seam — not bridged. `client` and `clock` types don't bridge
    /// (closure-bag struct, existential `Clock`).
    public init(
        client: HNClient,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.client = client
        self.clock = clock
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.commands = stream
        self.commandsContinuation = continuation
    }

    /// Single entry point for every user-driven mutation. `async` so
    /// callers that need completion (e.g. SwiftUI's `.refreshable`) can
    /// `await` the call. `.refresh` re-runs whichever surface the user
    /// is currently on — feed when `searchQuery` is empty, otherwise
    /// the current search.
    // SKIP @bridge
    public func dispatch(_ event: AppEvent) async {
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
        }
    }

    /// Long-lived debounced-fetch loop on every `state.searchQuery`
    /// write. The host `await`s this from `RootView`'s `.task` on iOS
    /// or `LaunchedEffect` on Android. Cancellation propagates from
    /// the host's surrounding Task.
    ///
    /// Events come from `state.searchQueryChanges` — see that property
    /// for the `.bufferingNewest(1)` rationale (handles burst writes
    /// during a slow consumer). Empty query → `clearSearch()`; the
    /// feed stays cached so dismissing the search overlay restores it
    /// without a network call.
    // SKIP @bridge
    public func runSearchQueryWatcher() async {
        for await query in state.searchQueryChanges {
            if query.isEmpty {
                clearSearch()
            } else {
                await runSearchFetch(query: query, debounce: Self.searchDebounce)
            }
        }
    }

    /// Empty-query path of the watcher, factored out so tests can drive
    /// it without spinning the full watcher Task.
    public func clearSearch() {
        tasks[.search] = nil
        state.searchIds = []
        state.searchLoadError = nil
        state.isSearchLoading = false
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

    public func runFeedFetch(debounce: Duration? = nil) async {
        state.isFeedLoading = true
        let task = makeFetchTask(debounce: debounce) { try await $0.frontPage() }
        tasks[.feed] = task
        do {
            // nil = superseded by a newer fetch. Leave isFeedLoading
            // asserted so the spinner stays visible until that fetch
            // settles.
            guard let ids = try await awaitFetch(task) else { return }
            state.feedIds = ids
            state.lastRefreshedAt = .now
            state.feedLoadError = nil
            state.isFeedLoading = false
        } catch {
            state.feedLoadError = error.localizedDescription
            state.isFeedLoading = false
        }
    }

    public func runSearchFetch(query: String, debounce: Duration? = nil) async {
        state.isSearchLoading = true
        let task = makeFetchTask(debounce: debounce) { try await $0.search(query) }
        tasks[.search] = task
        do {
            // nil = superseded by a newer fetch. Leave isSearchLoading
            // asserted so the spinner stays visible across the
            // cancel-and-replace. (`clearSearch()` is different — it
            // turns the flag off itself before cancelling the task.)
            guard let ids = try await awaitFetch(task) else { return }
            state.searchIds = ids
            state.searchLoadError = nil
            state.isSearchLoading = false
        } catch {
            state.searchLoadError = error.localizedDescription
            state.isSearchLoading = false
        }
    }

    /// Build a fetch task that sleeps for `debounce` (if set), then runs
    /// `body`. The Task body captures only Sendable values (`client`,
    /// `clock`) — never `self`.
    ///
    /// **`try` (not `try?`) on the sleep is load-bearing.** A test-mock
    /// closure that doesn't honor cancellation would otherwise fall
    /// through to the network call and commit stale data; the throw
    /// propagating is what makes cancel-and-replace robust against any
    /// client implementation.
    ///
    /// **`URLError(.cancelled)` is normalised to `CancellationError`.**
    /// `URLSession` surfaces task cancellation as `URLError.cancelled`,
    /// which would otherwise hit the dispatch arm's generic `catch` and
    /// write a transient `*LoadError = "cancelled"`.
    private func makeFetchTask(
        debounce: Duration?,
        body: @Sendable @escaping (HNClient) async throws -> [HNHit]
    ) -> Task<[HNHit], Error> {
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

    /// Await `task`, upsert its hits into the entity store, and return
    /// the id list. Returns `nil` if the task was cancelled — the
    /// caller short-circuits without touching its surface's state.
    /// Other errors propagate so the caller can record them.
    private func awaitFetch(_ task: Task<[HNHit], Error>) async throws -> [String]? {
        do {
            let hits = try await task.value
            for hit in hits { state.hits[hit.id] = hit }
            return hits.map(\.id)
        } catch is CancellationError {
            return nil
        }
    }
}
