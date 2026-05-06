import Foundation
import Observation

/// Tiny `@Observable` wrapper around `AppState`.
///
/// Lives between `AppModel` (which is deliberately *not* `@Observable`)
/// and the SwiftUI/`Observations` consumers — observation tracking flows
/// through the access path `appModel.state` → `_state.value` so callers
/// don't need to know the wrapper exists.
@Observable
final class AppStateObservable {
    var value: AppState = AppState()
}

/// The single source of truth for the example app.
///
/// This type is deliberately platform-agnostic. It carries no isolation
/// annotations and no `Sendable` conformance — its isolation is determined
/// by where it is used:
///
/// - On iOS, SwiftUI views are `@MainActor`, so reads and mutations from a
///   view body happen on `MainActor`.
/// - On Android, an `AndroidBridge` actor in `AppCoreAndroid` owns an
///   instance of this type and serialises all access through its executor.
///
/// All user-driven mutations enter through `dispatch(_:)`; both platforms
/// build the same `AppEvent` and call the same method (iOS directly,
/// Android via JSON over JNI).
///
/// Async methods declared here run on the caller's actor by default
/// (SE-0461 / `NonisolatedNonsendingByDefault`), so they don't introduce
/// any cross-actor hops.
public final class AppModel {
    private let _state = AppStateObservable()

    /// Read-only snapshot of the app state. Forwards to the inner
    /// `@Observable` wrapper so SwiftUI / `Observations` track changes
    /// through the same property access — `AppModel` itself doesn't
    /// need `@Observable`, which is what keeps the field list below
    /// free of `@ObservationIgnored` noise.
    public var state: AppState { _state.value }

    /// One-shot commands from the model to the UI — the symmetric
    /// counterpart to `dispatch(_:)`. The reducer yields onto a single
    /// continuation; iOS subscribes from a long-lived `.task`, Android's
    /// `AndroidBridge` subscribes from a Task that forwards JSON over JNI
    /// to a `CommandSink`. There is one consumer per platform binary, so
    /// the single-iterator constraint of `AsyncStream` is respected.
    public let commands: AsyncStream<AppCommand>

    private let commandsContinuation: AsyncStream<AppCommand>.Continuation

    private let client: HNClient

    /// Driver of the debounce sleep. `ContinuousClock()` in production;
    /// tests inject a `TestClock` so the 250 ms debounce doesn't translate
    /// into 250 ms of real-clock waiting per test.
    private let clock: any Clock<Duration>

    /// In-flight network task. Replaced (and the predecessor cancelled)
    /// on every `.refresh` and post-debounce `.setSearchQuery` — only one
    /// fetch runs at a time, and the latest dispatch always wins.
    private var searchTask: Task<[HNHit], Error>?

    /// Debounce window for `.setSearchQuery`. Exposed (rather than
    /// inlined) so tests can name the same duration when advancing
    /// their `TestClock`.
    static let searchDebounce: Duration = .milliseconds(250)

    public init(
        client: HNClient = HNClient(),
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
    /// `value`) — never `self`. State commits happen back here in the
    /// dispatch arm, after the `Task`'s value is awaited, so they run
    /// on the caller's actor where `self` natively lives.
    public func dispatch(_ event: AppEvent) async {
        switch event {
        case .toggleRead(let id):
            toggleRead(id)
        case .openStory(let id):
            openStory(id)
        case .refresh:
            await runFetch()
        case .setSearchQuery(let value):
            _state.value.searchQuery = value
            await runFetch(debounce: Self.searchDebounce)
        }
    }

    private func toggleRead(_ id: String) {
        if _state.value.readIds.contains(id) {
            _state.value.readIds.remove(id)
        } else {
            _state.value.readIds.insert(id)
        }
    }

    /// Mark a known story as read and, if it has a URL, ask the UI to
    /// present it. Unknown ids are a no-op — guarding here keeps
    /// `readIds` from accumulating ids that never corresponded to a hit.
    private func openStory(_ id: String) {
        guard let hit = _state.value.hits.first(where: { $0.id == id }) else { return }
        _state.value.readIds.insert(id)
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
    private func runFetch(debounce: Duration? = nil) async {
        searchTask?.cancel()

        let query = _state.value.searchQuery
        let task = Task<[HNHit], Error> { [client, clock] in
            if let debounce {
                try await clock.sleep(for: debounce)
            }
            return query.isEmpty
                ? try await client.frontPage()
                : try await client.search(query)
        }
        searchTask = task

        _state.value.isLoading = true

        do {
            let hits = try await task.value
            _state.value.hits = hits
            _state.value.lastRefreshedAt = .now
            _state.value.loadError = nil
            _state.value.isLoading = false
        } catch is CancellationError {
            // A newer dispatch superseded us. The newer one is responsible
            // for committing its own result; leave isLoading=true so the
            // spinner stays until that fetch settles.
            return
        } catch {
            _state.value.loadError = error.localizedDescription
            _state.value.isLoading = false
        }
    }
}
