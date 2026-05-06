import Foundation

/// A `Sendable` value-type snapshot of the app's state.
///
/// `AppState` is the mutable container. `AppModel` is a thin wrapper that
/// holds one of these and exposes a single `dispatch(_:)` entry point;
/// the JNI bridge serialises this snapshot as JSON to Android via
/// `toJSON()`.
///
/// Fields fall into three categories:
///
/// - **Stored** — wire-visible metadata grouped on `Stored`. Encoded by
///   default `Codable` synthesis; flattened into the JSON object by
///   `encode(to:)`. `AppState` forwards reads/writes via
///   `@dynamicMemberLookup` so callers say `state.searchQuery`, not
///   `state.stored.searchQuery`. Adding a new wire field is a one-line
///   change to `Stored`.
///
/// - **Internal** — `hits` and `readIds`. Reducer-only kernel that
///   never crosses the wire. Read state has a single source of truth in
///   `readIds`; `Story.isRead` is a projection, not stored anywhere.
///
/// - **Computed** — `stories`. The merged view-row projection of
///   `hits` × `readIds`. Computed properties aren't seen by `Codable`
///   synthesis, so this is the only field `encode(to:)` has to write
///   by hand.
@dynamicMemberLookup
public struct AppState: Sendable, Equatable, Encodable {

    // MARK: Stored (wire-visible, default-encoded)

    public struct Stored: Sendable, Equatable, Codable {
        public var searchQuery: String
        public var isLoading: Bool
        public var lastRefreshedAt: Date?
        public var loadError: String?

        public init(
            searchQuery: String = "",
            isLoading: Bool = false,
            lastRefreshedAt: Date? = nil,
            loadError: String? = nil
        ) {
            self.searchQuery = searchQuery
            self.isLoading = isLoading
            self.lastRefreshedAt = lastRefreshedAt
            self.loadError = loadError
        }
    }

    public var stored: Stored

    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Stored, T>) -> T {
        get { stored[keyPath: keyPath] }
        set { stored[keyPath: keyPath] = newValue }
    }

    // MARK: Internal (reducer kernel, off the wire)

    var hits: [HNHit]
    var readIds: Set<String>

    // MARK: Computed (projection — manually encoded below)

    public var stories: [Story] {
        hits.map { Story(hit: $0, isRead: readIds.contains($0.id)) }
    }

    // MARK: -

    public init(
        hits: [HNHit] = [],
        readIds: Set<String> = [],
        stored: Stored = Stored()
    ) {
        self.hits = hits
        self.readIds = readIds
        self.stored = stored
    }
}

extension AppState {
    /// Wire shape: `{ stories: [...], searchQuery: ..., isLoading: ..., ... }`.
    /// `stories` is the only thing `encode(to:)` writes by hand because
    /// it's computed and `Codable` synthesis can't see it. Everything in
    /// `Stored` is emitted by delegating to `stored.encode(to:)`, which
    /// flattens its keys into the same JSON object via the encoder's
    /// shared coding path. Internal kernel fields (`hits`, `readIds`)
    /// are never encoded.
    private enum WireKey: String, CodingKey {
        case stories
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(stories, forKey: .stories)
        try stored.encode(to: encoder)
    }

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
