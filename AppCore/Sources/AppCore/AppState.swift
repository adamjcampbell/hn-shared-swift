import Foundation

/// A `Sendable` value-type snapshot of the app's state.
///
/// `AppState` is the mutable container. `AppModel` is a thin `@Observable`
/// wrapper that holds one of these and exposes a single `dispatch(_:)`
/// entry point; the JNI bridge serialises this type as JSON.
public struct AppState: Sendable, Codable, Equatable {
    public var cities: [City]
    public var favorites: Set<String>
    public var globalFavoriteCount: Int
    public var lastRefreshedAt: Date?

    public init(
        cities: [City] = .demoData,
        favorites: Set<String> = [],
        globalFavoriteCount: Int = 0,
        lastRefreshedAt: Date? = nil
    ) {
        self.cities = cities
        self.favorites = favorites
        self.globalFavoriteCount = globalFavoriteCount
        self.lastRefreshedAt = lastRefreshedAt
    }
}

extension AppState {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public func toJSON() -> String {
        guard let data = try? Self.encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
