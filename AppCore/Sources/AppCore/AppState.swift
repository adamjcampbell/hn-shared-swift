import Foundation
import Observation

/// The single source of truth for the example app.
///
/// `AppState` is an `@Observable final class` so SwiftUI's fine-grained
/// invalidation (and the `Observations` async sequence on Android) track
/// property reads directly. There's no separate value-type snapshot held
/// alongside — the same instance flows from `AppModel` into the view
/// layer; the JSON snapshot is produced on demand by `toJSON()` whenever
/// the Android bridge needs to ship a transaction across JNI.
///
/// Properties fall into two groups, in the data-flow vocabulary of
/// WWDC19's *Data Flow Through SwiftUI*:
///
/// - **Stored sources of truth (encoded)** — `isLoading`,
///   `lastRefreshedAt`, `loadError`. Stored properties that
///   `encode(to:)` writes into the JSON snapshot the Kotlin `AppState`
///   data class consumes. Adding a new encoded field is one new
///   property plus one line in `encode(to:)`.
///
/// - **Stored sources of truth (per-property bridged, not encoded)** —
///   `searchQuery`. Both platforms drive this directly: iOS via
///   `@Bindable` + `$state.searchQuery`, Android via the per-property
///   JNI setter `appcoreSetSearchQuery` and the matching
///   `SearchQuerySink` push-back. The JSON snapshot deliberately omits
///   it — for primitives that two-way-bind to a UI control, per-property
///   bridging beats round-tripping through a snapshot. `AppModel`'s
///   `withObservationTracking` watcher fires the debounced fetch on
///   every write, regardless of which platform wrote it.
///
/// - **Stored sources of truth (internal — not encoded)** — `hits`
///   and `readIds`. The working set behind `dispatch(_:)`; never
///   encoded. `Story.isRead` is **derived** from `readIds` rather
///   than stored separately, which keeps read-state's single source
///   of truth in `readIds`.
///
/// - **Derived state** — `stories`. A computed property over
///   `hits` × `readIds` projecting into the view-row shape both UIs
///   render. Computed properties aren't seen by `Codable` synthesis,
///   so this is the one field `encode(to:)` writes by hand.
///
/// `Encodable` rather than `Codable` because the JSON only travels
/// Swift → Kotlin — we never decode an `AppState` on the Swift side.
/// Separately, the `encode(to:)` body is written by hand because the
/// `@Observable` macro rewrites stored properties into `_foo` backing
/// storage, which breaks the default `Codable` synthesis path.
@Observable
public final class AppState: Encodable {

    // MARK: Stored sources of truth (per-property bridged, not encoded)

    public var searchQuery: String = ""

    // MARK: Stored sources of truth (encoded)

    public var isLoading: Bool = false
    public var lastRefreshedAt: Date? = nil
    public var loadError: String? = nil

    // MARK: Stored sources of truth (internal — not encoded)

    var hits: [HNHit] = []
    var readIds: Set<String> = []

    // MARK: Derived state

    public var stories: [Story] {
        hits.map { Story(hit: $0, isRead: readIds.contains($0.id)) }
    }

    public init() {}

    // MARK: Encodable

    private enum WireKey: String, CodingKey {
        case stories
        case isLoading
        case lastRefreshedAt
        case loadError
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(stories, forKey: .stories)
        try container.encode(isLoading, forKey: .isLoading)
        try container.encodeIfPresent(lastRefreshedAt, forKey: .lastRefreshedAt)
        try container.encodeIfPresent(loadError, forKey: .loadError)
        // searchQuery is intentionally absent — see the type-level
        // doc-comment. It crosses JNI via its own setter + sink, not
        // via this snapshot.
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
