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

    public init() {}

    /// Single entry point for every user-driven mutation.
    ///
    /// `async` so callers that need completion (e.g. SwiftUI's
    /// `.refreshable` to dismiss the pull-to-refresh spinner) can `await`
    /// the call. Fire-and-forget call sites wrap in `Task { ... }` at the
    /// call site — that *is* the optional Task the UI controls.
    ///
    /// Why not `-> Task<Void, Never>?`: the `Task { ... }` initialiser
    /// takes a sending closure, and `AppModel` is deliberately
    /// non-`Sendable` (its isolation is whatever the caller provides —
    /// MainActor on iOS, the bridge actor on Android). Spawning a Task
    /// from inside a method on a non-`Sendable` class would either force
    /// AppModel to adopt a fixed actor (breaking the platform-agnostic
    /// design) or hit Swift 6 region-isolation errors. Pushing Task
    /// creation to the call site keeps each platform's isolation intact.
    public func dispatch(_ event: AppEvent) async {
        switch event {
        case .toggleFavorite(let id):
            toggleFavorite(id)
        case .refresh:
            await refresh()
        }
    }

    /// Toggle whether `id` is in the favorites set, then re-sort `cities`
    /// so favorites bubble to the top.
    ///
    /// Both mutations happen synchronously and are batched into a single
    /// `Observations` transaction — see SE-0475 §"Transactional semantics".
    private func toggleFavorite(_ id: String) {
        if state.favorites.contains(id) {
            state.favorites.remove(id)
        } else {
            state.favorites.insert(id)
        }
        // Capture `favorites` locally so the comparator doesn't re-read
        // `state` on every comparison (each read goes through the
        // observation registrar).
        let favorites = state.favorites
        state.cities.sort { lhs, rhs in
            let lhsFav = favorites.contains(lhs.id)
            let rhsFav = favorites.contains(rhs.id)
            if lhsFav != rhsFav { return lhsFav && !rhsFav }
            return lhs.name < rhs.name
        }
    }

    /// Simulate a network refresh. Sleeps for ~1s then mutates two
    /// observable properties whose changes are visible in the UI as a
    /// running counter and a timestamp.
    private func refresh() async {
        try? await Task.sleep(for: .seconds(1))
        state.globalFavoriteCount = Int.random(in: 100...10_000)
        state.lastRefreshedAt = .now
    }
}
