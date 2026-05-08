import Foundation
import Observation

/// The single source of truth for the example app.
///
/// `AppState` is an `@Observable final class` so SwiftUI's fine-grained
/// invalidation (and the `Observations` async sequence on Android) track
/// property reads directly. There's no separate value-type snapshot held
/// alongside — the same instance flows from `AppModel` into the view
/// layer; the JSON snapshot is produced on demand by `JNICoder.encode`
/// (in `AppCoreAndroid`) whenever the Android bridge needs to ship a
/// transaction across JNI.
///
/// Properties fall into two groups, in the data-flow vocabulary of
/// WWDC19's *Data Flow Through SwiftUI*:
///
/// - **Stored sources of truth (encoded)** — `lastRefreshedAt`,
///   `loadError`. Stored properties that `encode(to:)` writes into the
///   JSON snapshot the Kotlin `AppState` data class consumes. Adding a
///   new encoded field is one new property plus one line in
///   `encode(to:)`.
///
/// - **Stored sources of truth (per-property bridged, not encoded)** —
///   `searchQuery`, `isLoading`. Both platforms drive `searchQuery`
///   directly: iOS via `@Bindable` + `$state.searchQuery`, Android via
///   the per-property JNI setter `appcoreSetSearchQuery` and the
///   matching `SearchQuerySink` push-back. `isLoading` is one-way in
///   practice (only `runFetch` writes it), but rides the same
///   `AndroidBinding` machinery on Android via `IsLoadingSink`. The
///   JSON snapshot deliberately omits both — for primitives that
///   bind to a UI control or feed a UI predicate per change,
///   per-property bridging beats round-tripping through a snapshot.
///   `AppModel`'s `runSearchQueryWatcher` fires the debounced fetch
///   on every `searchQuery` write, regardless of which platform wrote
///   it.
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
/// **`isLoading` is bridged per-property, not via the snapshot.**
/// Pull-to-refresh indicator + empty-overlay flicker guard both want
/// per-fetch granularity (search-typing debounced fetches, not just
/// explicit `.refresh`); reading `state.isLoading` is the natural shape
/// on both platforms. iOS reads it directly through SwiftUI's tracking;
/// Android consumes it via `IsLoadingSink` + `BridgedSource` (same
/// machinery as `searchQuery`). It's deliberately not in the JSON
/// snapshot — primitives that drive UI predicates on every change ride
/// the per-property bridge.
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
    public var isLoading: Bool = false

    // MARK: Stored sources of truth (encoded)

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
        case lastRefreshedAt
        case loadError
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(stories, forKey: .stories)
        try container.encodeIfPresent(lastRefreshedAt, forKey: .lastRefreshedAt)
        try container.encodeIfPresent(loadError, forKey: .loadError)
        // searchQuery and isLoading are intentionally absent — see the
        // type-level doc-comment. They cross JNI via their own setter +
        // sink, not via this snapshot.
    }
}
