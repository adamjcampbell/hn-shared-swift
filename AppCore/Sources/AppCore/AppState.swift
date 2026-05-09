import Foundation
import Observation

/// The single source of truth for the example app.
///
/// `AppState` is an `@Observable final class` so SwiftUI's fine-grained
/// invalidation (and per-composable `withObservationTracking` scopes on
/// Android) track property reads directly. There's no separate value-type
/// snapshot alongside — the same instance flows from `AppModel` into the
/// view layer; complex types like `[Story]` cross JNI as JSON on demand
/// (via `appcoreGetStoriesJSON`), while scalars cross as direct JNI getters.
///
/// Properties fall into two groups, in the data-flow vocabulary of
/// WWDC19's *Data Flow Through SwiftUI*:
///
/// - **Stored sources of truth** — `searchQuery`, `isLoading`,
///   `lastRefreshedAt`, `loadError`. Written by `dispatch(_:)` or by
///   platform-specific setters; read directly by both SwiftUI (via tracking)
///   and Android (via JNI getters inside `appcoreObserve` scopes).
///   `AppModel`'s `runSearchQueryWatcher` fires the debounced fetch on
///   every `searchQuery` write, regardless of which platform wrote it.
///
/// - **Stored sources of truth (internal)** — `hits` and `readIds`. The
///   working set behind `dispatch(_:)`; never exposed directly. `Story.isRead`
///   is derived from `readIds` rather than stored separately.
///
/// - **Derived state** — `stories`. A computed property over
///   `hits` × `readIds` projecting into the view-row shape both UIs render.
@Observable
public final class AppState {

    // MARK: Stored sources of truth

    public var searchQuery: String = ""
    public var isLoading: Bool = false
    public var lastRefreshedAt: Date? = nil
    public var loadError: String? = nil

    // MARK: Stored sources of truth (internal)

    var hits: [HNHit] = []
    var readIds: Set<String> = []

    // MARK: Derived state

    public var stories: [Story] {
        hits.map { Story(hit: $0, isRead: readIds.contains($0.id)) }
    }

    public init() {}
}
