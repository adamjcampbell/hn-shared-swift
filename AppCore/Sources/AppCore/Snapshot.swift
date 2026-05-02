import Foundation

/// A `Sendable` value-type snapshot of `AppState`.
///
/// Used as the unit of state delivery from Swift to Kotlin. Values are
/// JSON-encoded at the JNI boundary; see §2.6.
public struct Snapshot: Sendable, Codable, Equatable {
    public let cities: [City]
    public let favorites: Set<String>
    public let globalFavoriteCount: Int
    public let lastRefreshedAt: Date?

    public init(from state: AppState) {
        self.cities = state.cities
        self.favorites = state.favorites
        self.globalFavoriteCount = state.globalFavoriteCount
        self.lastRefreshedAt = state.lastRefreshedAt
    }
}
