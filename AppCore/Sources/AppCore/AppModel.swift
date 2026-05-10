import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Owns the app's `AppState` and the `dispatch(_:)` method that
/// mutates it in response to user events.
///
/// `AppState` is the `@Observable` reference; `AppModel` itself is not
/// `@Observable` because its other fields (`client`, `clock`, `searchTask`,
/// the commands continuation) aren't meant to be observed and adding
/// `@ObservationIgnored` to each would only add noise.
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

    /// In-flight network task. Replaced (and the predecessor cancelled)
    /// on every `.refresh` and on each `state.searchQuery` write — only
    /// one fetch runs at a time, and the latest dispatch always wins.
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

    /// Single entry point for every user-driven mutation.
    ///
    /// `async` so callers that need completion (e.g. SwiftUI's
    /// `.refreshable` to dismiss the pull-to-refresh spinner) can `await`
    /// the call. Cross-platform: `dispatch` is statically nonisolated
    /// under SE-0461 and runs on the caller's actor at runtime.
    ///
    /// **Why this works under Swift 6 strict concurrency.** The fetch
    /// `Task` deliberately captures only Sendable values (`client`,
    /// `clock`, `query`) — never `self`. State commits happen back here
    /// in the dispatch arm, after the `Task`'s value is awaited, so
    /// they run on the caller's actor where `self` natively lives.
    // SKIP @bridge
    public func dispatch(_ event: AppEvent) async {
        switch event {
        case .toggleRead(let id):
            toggleRead(id)
        case .openStory(let id):
            openStory(id)
        case .refresh:
            await runFetch()
        }
    }

    /// Long-lived loop that drives a debounced fetch on every write to
    /// `state.searchQuery`. The host (`RootView`'s `.task` on iOS,
    /// `Bridge.attach` on Android) `await`s this from inside its
    /// own Task; cancellation propagates from the host's surrounding
    /// Task.
    ///
    /// Why this works as a plain async method (where `start()` spawning
    /// a `Task { [self] in ... }` doesn't): there's no unstructured
    /// `Task` creation here. Under SE-0461 the body runs on the
    /// caller's actor; the `for await` iterator is non-Sendable but
    /// stays in that actor's region; `runFetch` is called on the same
    /// actor. The `[#SendingClosureRisksDataRace]` hole only fires when
    /// you put `self` inside a `sending` closure (Task.init,
    /// async-let, TaskGroup.addTask). A plain async method body has
    /// no such hop.
    ///
    /// `dropFirst()` skips `ObservedKeyPath`'s iteration-start emission
    /// so the host's first-appear `.refresh` isn't duplicated.
    /// `runFetch` reads `state.searchQuery` on entry, so a burst of
    /// writes coalesces naturally — the inner `searchTask`
    /// cancel-and-replace handles overlapping fetches.
    // SKIP @bridge
    public func runSearchQueryWatcher() async {
        for await _ in state.observe(\.searchQuery).dropFirst() {
            await runFetch(debounce: Self.searchDebounce)
        }
    }

    private func toggleRead(_ id: String) {
        if state.readIds.contains(id) {
            state.readIds.remove(id)
        } else {
            state.readIds.insert(id)
        }
    }

    /// Mark a known story as read and, if it has a URL, ask the UI to
    /// present it. Unknown ids are a no-op — guarding here keeps
    /// `readIds` from accumulating ids that never corresponded to a hit.
    private func openStory(_ id: String) {
        guard let hit = state.hits.first(where: { $0.id == id }) else { return }
        state.readIds.insert(id)
        if let url = hit.url {
            commandsContinuation.yield(.presentURL(value: url))
        }
    }

    /// Cancel-and-replace a single in-flight fetch task.
    ///
    /// The Task body captures only Sendable values (`client`, `clock`)
    /// plus the local `query` and `debounce` — never `self`. When a new
    /// dispatch arrives, it cancels the prior task; that task's
    /// `clock.sleep` throws `CancellationError`, the throw propagates
    /// through the Task body without ever reaching the fetch call, and
    /// the prior dispatch's `try await task.value` re-throws into the
    /// `catch is CancellationError` arm — which returns without
    /// committing anything to `state`. `debounce: nil` runs the fetch
    /// immediately.
    ///
    /// **`try` (not `try?`) on the sleep is load-bearing.** Swallowing
    /// the throw with `try?` would let cancelled tasks fall through to
    /// the fetch call, and a test-mock closure that doesn't honor
    /// cancellation (most don't) would then succeed for the cancelled
    /// query and commit stale data. Letting the throw propagate is what
    /// makes the cancel-and-replace property robust against any client
    /// implementation, mock or live.
    ///
    /// **`URLError(.cancelled)` is normalised to `CancellationError`
    /// inside the Task body** — `URLSession` surfaces task cancellation
    /// as `URLError.cancelled` rather than `CancellationError`, so a
    /// fetch already in flight when a newer dispatch arrives would
    /// otherwise fall through to the generic `catch` arm and surface as
    /// a transient `loadError = "cancelled"` until the newer fetch
    /// settles. Re-throwing as `CancellationError` keeps the dispatch
    /// arm a single uniform "this run was superseded" path.
    public func runFetch(debounce: Duration? = nil) async {
        searchTask?.cancel()
        state.isLoading = true

        let query = state.searchQuery
        let task = Task<[HNHit], Error> { [client, clock] in
            if let debounce {
                try await clock.sleep(for: debounce)
            }
            do {
                return query.isEmpty
                    ? try await client.frontPage()
                    : try await client.search(query)
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            }
        }
        searchTask = task

        do {
            let hits = try await task.value
            state.hits = hits
            state.lastRefreshedAt = .now
            state.loadError = nil
            state.isLoading = false
        } catch is CancellationError {
            // A newer dispatch superseded us. The newer one is responsible
            // for committing its own result; leave isLoading=true so the
            // spinner / empty-overlay guard stays asserted until that
            // fetch settles.
            return
        } catch {
            state.loadError = error.localizedDescription
            state.isLoading = false
        }
    }
}
