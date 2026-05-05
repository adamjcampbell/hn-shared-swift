import Foundation

/// A `Sendable` value-type snapshot of the app's state.
///
/// `AppState` is the mutable container. `AppModel` is a thin `@Observable`
/// wrapper that holds one of these and exposes a single `dispatch(_:)`
/// entry point; the JNI bridge serialises this type as JSON.
public struct AppState: Sendable, Codable, Equatable {
    public var stories: [Story]
    public var read: Set<String>
    public var searchQuery: String
    public var isLoading: Bool
    public var lastRefreshedAt: Date?
    public var loadError: String?

    public init(
        stories: [Story] = [],
        read: Set<String> = [],
        searchQuery: String = "",
        isLoading: Bool = false,
        lastRefreshedAt: Date? = nil,
        loadError: String? = nil
    ) {
        self.stories = stories
        self.read = read
        self.searchQuery = searchQuery
        self.isLoading = isLoading
        self.lastRefreshedAt = lastRefreshedAt
        self.loadError = loadError
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
