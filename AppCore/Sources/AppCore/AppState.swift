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
/// Async methods declared here run on the caller's actor by default
/// (SE-0461 / `NonisolatedNonsendingByDefault`), so they don't introduce
/// any cross-actor hops.
@Observable
public final class AppState {
    public private(set) var cities: [City] = .demoData
    public private(set) var favorites: Set<String> = []
    public private(set) var globalFavoriteCount: Int = 0
    public private(set) var lastRefreshedAt: Date? = nil

    public init() {}

    /// Toggle whether `id` is in the favorites set, then re-sort `cities`
    /// so favorites bubble to the top.
    ///
    /// Both mutations happen synchronously and are batched into a single
    /// `Observations` transaction — see SE-0475 §"Transactional semantics".
    public func toggleFavorite(_ id: String) {
        if favorites.contains(id) {
            favorites.remove(id)
        } else {
            favorites.insert(id)
        }
        cities.sort { lhs, rhs in
            let lhsFav = favorites.contains(lhs.id)
            let rhsFav = favorites.contains(rhs.id)
            if lhsFav != rhsFav { return lhsFav && !rhsFav }
            return lhs.name < rhs.name
        }
    }

    /// Simulate a network refresh. Sleeps for ~1s then mutates two
    /// observable properties whose changes are visible in the UI as a
    /// running counter and a timestamp.
    ///
    /// Because of `NonisolatedNonsendingByDefault` (SE-0461), this method
    /// runs on the caller's actor. The `await` suspends the actor's queue,
    /// but resumes back on the same actor — so the mutations after the
    /// sleep are still on the caller's isolation domain. There is no
    /// cross-actor data race risk.
    public func refresh() async {
        try? await Task.sleep(for: .seconds(1))
        globalFavoriteCount = Int.random(in: 100...10_000)
        lastRefreshedAt = .now
    }
}
