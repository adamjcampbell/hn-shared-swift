import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Owns the app's `AppState` and the `dispatch(_:)` method that
/// mutates it in response to user events.
///
/// `AppState` is the `@Observable` reference; `AppModel` itself is not
/// `@Observable` because its other fields (`client`, `clock`, in-flight
/// tasks, the commands continuation) aren't meant to be observed and
/// adding `@ObservationIgnored` to each would only add noise.
///
/// Async methods declared here run on the caller's actor by default
/// (SE-0461 / `NonisolatedNonsendingByDefault`), so they don't introduce
/// any cross-actor hops. Bridged to Kotlin via SkipFuse — see the
/// `// SKIP @bridge` markers below.
// SKIP @bridge
public final class AppModel {
    /// The single observable state instance. SwiftUI tracks property
    /// reads on this directly; on Android, SkipFuse routes the same
    /// observation tracking through Compose's snapshot system.
    // SKIP @bridge
    public let state = AppState()

    /// One-shot commands from the model to the UI — the symmetric
    /// counterpart to `dispatch(_:)`. iOS subscribes with `for await`
    /// from a long-lived `.task`. On Android, Compose code can convert
    /// this to a `kotlinx.coroutines.flow.Flow` (SkipFuse's `AsyncStream`
    /// implements `KotlinConverting<Flow>`).
    // SKIP @bridge
    public let commands: AsyncStream<AppCommand>

    private let commandsContinuation: AsyncStream<AppCommand>.Continuation

    private let client: HNClient

    /// Driver of the debounce sleep. `ContinuousClock()` in production;
    /// tests inject a `TestClock` so the 250 ms debounce doesn't translate
    /// into 250 ms of real-clock waiting per test.
    private let clock: any Clock<Duration>

    /// In-flight feed fetch. Cancelled and replaced on each
    /// `runFeedFetch`. Independent of `searchTask` — a feed refresh
    /// never cancels a search and vice versa.
    private var feedTask: Task<[HNHit], Error>?

    /// In-flight search fetch. Cancelled and replaced on each
    /// `runSearchFetch`, and explicitly cancelled when the query
    /// becomes empty.
    private var searchTask: Task<[HNHit], Error>?

    /// Debounce window applied between a `state.searchQuery` write and
    /// the resulting fetch. Exposed (rather than inlined) so tests can
    /// name the same duration when advancing their `TestClock`.
    public static let searchDebounce: Duration = .milliseconds(250)

    /// Production / Kotlin-side init — bridged.
    // SKIP @bridge
    public init() {
        self.client = HNClient()
        self.clock = ContinuousClock()
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.commands = stream
        self.commandsContinuation = continuation
    }

    /// Test seam — not bridged. `client` and `clock` types don't bridge
    /// (closure-bag struct, existential `Clock`), and tests always
    /// pass both explicitly anyway.
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

    /// Single entry point for every user-driven mutation. `.refresh`
    /// re-runs whichever surface the user is currently on — feed when
    /// `searchQuery` is empty, otherwise the current search.
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
        searchTask?.cancel()
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

    /// Cancel-and-replace the in-flight feed fetch.
    ///
    /// The Task body captures only Sendable values (`client`, `clock`)
    /// plus the local `debounce` — never `self`. State commits happen
    /// here on the caller's actor after `try await task.value`.
    ///
    /// **`try` (not `try?`) on the sleep is load-bearing.** A test-mock
    /// closure that doesn't honor cancellation would otherwise fall
    /// through to the network call and commit stale data; the throw
    /// propagating is what makes cancel-and-replace robust.
    ///
    /// **`URLError(.cancelled)` is normalised to `CancellationError`.**
    /// `URLSession` surfaces task cancellation as `URLError.cancelled`,
    /// which would otherwise hit the dispatch arm's generic `catch` and
    /// write a transient `feedLoadError = "cancelled"`.
    ///
    /// **The `CancellationError` arm intentionally does not flip
    /// `isFeedLoading` back to false.** A newer dispatch is responsible
    /// for committing its own result; leaving the flag asserted keeps
    /// the spinner visible until the newer fetch settles.
    public func runFeedFetch(debounce: Duration? = nil) async {
        feedTask?.cancel()
        state.isFeedLoading = true

        let task = Task<[HNHit], Error> { [client, clock] in
            if let debounce {
                try await clock.sleep(for: debounce)
            }
            do {
                return try await client.frontPage()
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            }
        }
        feedTask = task

        do {
            let hits = try await task.value
            for hit in hits { state.hits[hit.id] = hit }
            state.feedIds = hits.map(\.id)
            state.lastRefreshedAt = .now
            state.feedLoadError = nil
            state.isFeedLoading = false
        } catch is CancellationError {
            return
        } catch {
            state.feedLoadError = error.localizedDescription
            state.isFeedLoading = false
        }
    }

    /// Cancel-and-replace the in-flight search fetch.
    ///
    /// `state.isSearchLoading` flips synchronously on entry so the UI
    /// spinner activates from the first keystroke and stays on across
    /// cancel-and-replace until results land. The `CancellationError`
    /// arm leaves the flag asserted (a newer search in flight will
    /// turn it off); `clearSearch()` is different — it turns the flag
    /// off itself before cancelling the task.
    public func runSearchFetch(query: String, debounce: Duration? = nil) async {
        searchTask?.cancel()
        state.isSearchLoading = true

        let task = Task<[HNHit], Error> { [client, clock] in
            if let debounce {
                try await clock.sleep(for: debounce)
            }
            do {
                return try await client.search(query)
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            }
        }
        searchTask = task

        do {
            let hits = try await task.value
            for hit in hits { state.hits[hit.id] = hit }
            state.searchIds = hits.map(\.id)
            state.searchLoadError = nil
            state.isSearchLoading = false
        } catch is CancellationError {
            return
        } catch {
            state.searchLoadError = error.localizedDescription
            state.isSearchLoading = false
        }
    }
}
