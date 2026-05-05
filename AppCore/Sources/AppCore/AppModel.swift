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

    /// Bumped synchronously on every `.setSearchQuery` and `.refresh`.
    ///
    /// Two callers read it:
    ///
    /// - The post-sleep guard in `.setSearchQuery` — older dispatches
    ///   whose keystroke is no longer the latest return without firing
    ///   a fetch.
    /// - The post-fetch guard in `runFetch` — if a newer dispatch (any
    ///   kind) bumped the epoch while we were awaiting `body()`, the
    ///   newer one is what should win, so we drop our result silently.
    ///
    /// One counter handles both cases because the actor (MainActor on
    /// iOS, `AndroidBridge` on Android) serialises synchronous code.
    /// `queryEpoch &+= 1` and `let myEpoch = queryEpoch` are atomic
    /// against each other; only `await` points let another dispatch
    /// interleave, and at every such point the epoch invariant ("I'm
    /// the latest iff `myEpoch == queryEpoch`") is what we want.
    @ObservationIgnored
    private var queryEpoch: UInt64 = 0

    /// Debounce window for `.setSearchQuery`. Hard-coded; the test
    /// harness uses time-based timing assertions rather than mutating
    /// this constant (so we don't need a strict-concurrency-unfriendly
    /// `static var`).
    static let searchDebounce: Duration = .milliseconds(250)

    public init(client: HNClient = HNClient()) {
        self.client = client
    }

    /// Single entry point for every user-driven mutation.
    ///
    /// `async` so callers that need completion (e.g. SwiftUI's
    /// `.refreshable` to dismiss the pull-to-refresh spinner) can
    /// `await` the call.
    ///
    /// **Why debounce sleeps inline rather than spawning a Task.**
    /// Under SE-0461 (`NonisolatedNonsendingByDefault`, enabled
    /// package-wide) an unannotated `async` method is statically
    /// `nonisolated(nonsending)` even though it runs on the caller's
    /// actor at runtime. The proposal explicitly states *"unstructured
    /// tasks created in nonisolated functions never run on an actor
    /// unless explicitly specified."* `Task.init`'s
    /// `@_inheritActorContext` only inherits *static* isolation, and
    /// SE-0420's `#isolation`-defaulted `isolated` parameter — the
    /// obvious "explicit specification" — does not (in Swift 6.3)
    /// propagate into the Task closure's inheritance. So we don't
    /// spawn a Task here; the caller's outer Task is the structural
    /// unit. Each `.setSearchQuery` dispatch sleeps inline; the
    /// `queryEpoch` check after the sleep filters out older dispatches
    /// whose keystroke is no longer the latest. Multiple in-flight
    /// dispatches sleep concurrently on the caller's actor (each
    /// `Task.sleep` releases the actor), and only the latest survives
    /// the epoch check.
    public func dispatch(_ event: AppEvent) async {
        switch event {
        case .toggleRead(let id):
            toggleRead(id)
        case .refresh:
            queryEpoch &+= 1
            await runFetch {
                self.state.searchQuery.isEmpty
                    ? try await self.client.frontPage()
                    : try await self.client.search(self.state.searchQuery)
            }
        case .setSearchQuery(let value):
            state.searchQuery = value
            queryEpoch &+= 1
            let myEpoch = queryEpoch
            do {
                try await Task.sleep(for: Self.searchDebounce)
            } catch {
                return
            }
            guard myEpoch == queryEpoch else { return }
            await runFetch {
                value.isEmpty
                    ? try await self.client.frontPage()
                    : try await self.client.search(value)
            }
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
        // Capture the epoch the calling dispatch arm just bumped. The
        // capture is atomic with respect to other dispatches because the
        // actor is still serialised between `dispatch`'s bump and the
        // first `await` inside this method.
        let myEpoch = queryEpoch
        state.isLoading = true
        state.loadError = nil
        do {
            let stories = try await body()
            // Stale: a newer dispatch started while we were awaiting, so
            // its result is what should win. Drop ours silently.
            guard myEpoch == queryEpoch else { return }
            state.stories = stories
            state.lastRefreshedAt = .now
            state.isLoading = false
        } catch is CancellationError {
            // A new fetch is on its way; leave isLoading=true so the
            // spinner stays until that fetch settles.
            return
        } catch {
            guard myEpoch == queryEpoch else { return }
            state.loadError = error.localizedDescription
            state.isLoading = false
        }
    }
}
