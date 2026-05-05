import Foundation
import Observation

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
@Observable
public final class AppModel {
    public private(set) var state: AppState = AppState()

    @ObservationIgnored
    private let client: HNClient

    /// In-flight network task. Replaced (and the predecessor cancelled)
    /// on every `.refresh` and post-debounce `.setSearchQuery` — only one
    /// fetch runs at a time, and the latest dispatch always wins.
    @ObservationIgnored
    private var searchTask: Task<FetchOutcome, Never>?

    /// Debounce window for `.setSearchQuery`.
    static let searchDebounce: Duration = .milliseconds(250)

    public init(client: HNClient = HNClient()) {
        self.client = client
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
    /// on the caller's actor where `self` natively lives. That's how we
    /// can have a stored `searchTask: Task<…>?` field on a non-Sendable
    /// `@Observable` class without tripping the SE-0461 hole.
    public func dispatch(_ event: AppEvent) async {
        switch event {
        case .toggleRead(let id):
            toggleRead(id)
        case .refresh:
            await runFetch(debounce: .immediately)
        case .setSearchQuery(let value):
            state.searchQuery = value
            await runFetch(debounce: .after(Self.searchDebounce))
        }
    }

    private func toggleRead(_ id: String) {
        if state.read.contains(id) {
            state.read.remove(id)
        } else {
            state.read.insert(id)
        }
    }

    /// Cancel-and-replace a single in-flight fetch task.
    ///
    /// The Task body captures only Sendable values (`client`, `query`,
    /// `debounce`). When a new dispatch arrives, it cancels the prior
    /// task; that task's `URLSession.data(from:)` throws
    /// `CancellationError`, the body returns `.cancelled`, and the prior
    /// dispatch's `await searchTask?.value` here resolves to `.cancelled`
    /// — at which point the prior dispatch returns without committing
    /// anything to `state`.
    private func runFetch(debounce: DebounceMode) async {
        searchTask?.cancel()

        let query = state.searchQuery
        let task = Task<FetchOutcome, Never> { [client] in
            if case .after(let duration) = debounce {
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return .cancelled
                }
            }
            do {
                let stories = query.isEmpty
                    ? try await client.frontPage()
                    : try await client.search(query)
                return .success(stories)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failure(error.localizedDescription)
            }
        }
        searchTask = task

        state.isLoading = true
        state.loadError = nil

        switch await task.value {
        case .cancelled:
            // A newer dispatch superseded us. The newer one is responsible
            // for committing its own result; leave isLoading=true so the
            // spinner stays until that fetch settles.
            return
        case .success(let stories):
            state.stories = stories
            state.lastRefreshedAt = .now
            state.isLoading = false
        case .failure(let message):
            state.loadError = message
            state.isLoading = false
        }
    }
}

private enum DebounceMode: Sendable {
    case immediately
    case after(Duration)
}

private enum FetchOutcome: Sendable {
    case success([Story])
    case failure(String)
    case cancelled
}
