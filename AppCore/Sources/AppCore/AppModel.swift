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

    /// Monotonic counter incremented on every `.refresh`. Each fetch
    /// captures its epoch and only commits results if the epoch is still
    /// current when the response lands. On iOS this is redundant because
    /// SwiftUI's `task(id:)` cancels the prior dispatch (and `URLSession`
    /// throws `CancellationError`); on Android the JNI dispatch is
    /// fire-and-forget so Kotlin-side cancellation can't propagate, and
    /// the epoch is what makes "fast typing → only the last query's
    /// results land" actually true.
    @ObservationIgnored
    private var requestEpoch: UInt64 = 0

    public init(client: HNClient = HNClient()) {
        self.client = client
    }

    /// Single entry point for every user-driven mutation.
    ///
    /// `async` so callers that need completion (e.g. SwiftUI's
    /// `.refreshable` to dismiss the pull-to-refresh spinner, or a
    /// `.task(id:)` driving debounced search) can `await` the call.
    /// Cancellation propagates: when the surrounding Task is cancelled,
    /// the inner `URLSession.data` throws `CancellationError`, which
    /// `runFetch` swallows without updating `state.stories`. This is
    /// what makes "type fast → only the last query's results land"
    /// work identically on both platforms.
    public func dispatch(_ event: AppEvent) async {
        switch event {
        case .toggleRead(let id):
            toggleRead(id)
        case .refresh:
            await runFetch {
                self.state.searchQuery.isEmpty
                    ? try await self.client.frontPage()
                    : try await self.client.search(self.state.searchQuery)
            }
        case .setSearchQuery(let value):
            // Synchronous local update only. Debouncing + the actual
            // network fetch is driven by the platform UI (`task(id:)` on
            // iOS, `LaunchedEffect` on Android), which fires `.refresh`
            // after a 250 ms debounce. Doing it that way lets the
            // platform's structured concurrency primitives handle
            // cancellation, which sidesteps the "spawn a Task that
            // captures non-Sendable self" hole that Swift 6 region
            // isolation closes off.
            state.searchQuery = value
        }
    }

    private func toggleRead(_ id: String) {
        if state.read.contains(id) {
            state.read.remove(id)
        } else {
            state.read.insert(id)
        }
    }

    /// Run a network request, mirroring loading/error state into `AppState`.
    /// The two synchronous mutations on success (`stories` + `lastRefreshedAt`)
    /// batch into one `Observations` transaction (SE-0475) on Android.
    private func runFetch(_ body: () async throws -> [Story]) async {
        requestEpoch &+= 1
        let myEpoch = requestEpoch
        state.isLoading = true
        state.loadError = nil
        do {
            let stories = try await body()
            // Stale: a newer .refresh started while we were awaiting, so
            // its result is what should win. Drop ours silently.
            guard myEpoch == requestEpoch else { return }
            state.stories = stories
            state.lastRefreshedAt = .now
            state.isLoading = false
        } catch is CancellationError {
            // A new fetch is on its way (the platform UI re-fired refresh
            // because the search text changed). Leave isLoading=true so
            // the spinner stays until that fetch settles.
            return
        } catch {
            guard myEpoch == requestEpoch else { return }
            state.loadError = error.localizedDescription
            state.isLoading = false
        }
    }
}
