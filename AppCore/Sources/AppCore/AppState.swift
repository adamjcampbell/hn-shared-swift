import Foundation
import Observation
import SkipFuse

/// The single source of truth for the example app.
///
/// `AppState` is an `@Observable final class` so SwiftUI's fine-grained
/// invalidation tracks property reads directly on iOS. On Android, SkipFuse
/// intercepts the same observation tracking and routes property
/// reads/mutations through Compose's snapshot system — reads inside a
/// `@Composable` are recorded, mutations trigger recomposition.
// SKIP @bridge
@Observable
public final class AppState {

    // MARK: Stored sources of truth

    // SKIP @bridge
    public var searchQuery: String = ""
    // SKIP @bridge
    public var isLoading: Bool = false
    // SKIP @bridge
    public var lastRefreshedAt: Date? = nil
    // SKIP @bridge
    public var loadError: String? = nil

    // MARK: Stored sources of truth (internal)

    var hits: [HNHit] = []
    var readIds: Set<String> = []

    // MARK: Derived state

    // SKIP @bridge
    public var stories: [Story] {
        hits.map { Story(hit: $0, isRead: readIds.contains($0.id)) }
    }

    // SKIP @bridge
    public init() {}
}
