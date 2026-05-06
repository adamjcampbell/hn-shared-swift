import Foundation
import Observation

/// The single source of truth for the example app.
///
/// `AppState` is an `@Observable final class` so SwiftUI views and the
/// `Observations` async sequence on Android both track property reads
/// directly. There's no separate value-type snapshot held alongside —
/// the same instance flows from `AppModel` into the view layer; the
/// JSON wire format is produced on demand by `toJSON()` whenever the
/// Android bridge needs to ship a transaction across JNI.
///
/// Fields fall into three categories:
///
/// - **Wire-visible** — `searchQuery`, `isLoading`, `lastRefreshedAt`,
///   `loadError`. Encoded by `encode(to:)` and consumed by the Kotlin
///   `AppState` data class. Adding a new wire field is one new property
///   plus one line in `encode(to:)`.
///
/// - **Internal kernel** — `hits` and `readIds`. Reducer-only state that
///   never crosses the wire. Read-state has a single source of truth in
///   `readIds`; `Story.isRead` is a projection, not stored anywhere.
///
/// - **Computed projection** — `stories`. Maps `hits` × `readIds` into
///   the view-row shape the UIs actually consume. Computed properties
///   aren't seen by `Codable` synthesis; this is the only field
///   `encode(to:)` writes by hand.
///
/// `Encodable` (not `Codable`): the JSON only travels Swift → Kotlin.
/// We never decode an `AppState` on the Swift side. Custom `encode(to:)`
/// is required because the `@Observable` macro rewrites stored
/// properties into `_foo` backing storage, which breaks the default
/// synthesis path.
@Observable
public final class AppState: Encodable {

    // MARK: Wire-visible

    public var searchQuery: String = ""
    public var isLoading: Bool = false
    public var lastRefreshedAt: Date? = nil
    public var loadError: String? = nil

    // MARK: Internal kernel (off the wire)

    var hits: [HNHit] = []
    var readIds: Set<String> = []

    // MARK: Computed projection

    public var stories: [Story] {
        hits.map { Story(hit: $0, isRead: readIds.contains($0.id)) }
    }

    public init() {}

    // MARK: Encodable

    private enum WireKey: String, CodingKey {
        case stories
        case searchQuery
        case isLoading
        case lastRefreshedAt
        case loadError
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(stories, forKey: .stories)
        try container.encode(searchQuery, forKey: .searchQuery)
        try container.encode(isLoading, forKey: .isLoading)
        try container.encodeIfPresent(lastRefreshedAt, forKey: .lastRefreshedAt)
        try container.encodeIfPresent(loadError, forKey: .loadError)
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
