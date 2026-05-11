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
///
/// Hits are stored in a normalised dictionary keyed by id; the feed and
/// search surfaces project it through their own ordered id lists. A story
/// that appears in both surfaces is stored once, so toggle-read flows to
/// both projections through `readIds` without any cross-surface sync.
// SKIP @bridge
@Observable
public final class AppState {

    // MARK: Stored sources of truth (public, bridged)

    /// `@Observable` drives reads-to-recompose (SwiftUI / Compose);
    /// `searchQueryChanges` drives the writes-to-fetch consumer in
    /// `AppModel.runSearchQueryWatcher`. Two channels deliberately —
    /// trying to bridge them with a `withObservationTracking`-based
    /// iterator created an arm/disarm window where bursts of writes
    /// during a long `await` were silently dropped.
    // SKIP @bridge
    public var searchQuery: String = "" {
        didSet { searchQueryEvents.yield(searchQuery) }
    }
    // SKIP @bridge
    public var isFeedLoading: Bool = false
    // SKIP @bridge
    public var isSearchLoading: Bool = false
    // SKIP @bridge
    public var lastRefreshedAt: Date? = nil
    // SKIP @bridge
    public var feedLoadError: String? = nil
    // SKIP @bridge
    public var searchLoadError: String? = nil

    // MARK: Stored sources of truth (internal)

    /// Entity store. Every fetch upserts the hits it returned — feed
    /// and search never clobber each other's entries. ~80 entries per
    /// session (front page + one search), so no pruning.
    var hits: [String: HNHit] = [:]
    var readIds: Set<String> = []

    /// Bridged so writes propagate through SkipFuse's `@Observable`
    /// bridge to Compose's `MutableStateBacking`. Internal
    /// stored-property writes don't reliably trigger Compose
    /// recomposition through a bridged computed projection
    /// (`feedStories` / `searchResults`) — `clearSearch()` would
    /// otherwise reset `searchIds` to `[]` without the search overlay
    /// re-rendering. Kotlin doesn't consume these directly.
    // SKIP @bridge
    public var feedIds: [String] = []
    // SKIP @bridge
    public var searchIds: [String] = []

    // MARK: searchQuery event stream

    /// Consumed by `AppModel.runSearchQueryWatcher`.
    /// `.bufferingNewest(1)` collapses bursts during a slow consumer
    /// (e.g. `runSearchFetch` parked in debounce + network) to a single
    /// emission of the final value — matches the debounce/settle
    /// semantics. `yield` is synchronous and non-blocking.
    let searchQueryChanges: AsyncStream<String>
    private let searchQueryEvents: AsyncStream<String>.Continuation

    // MARK: Derived view rows

    /// `compactMap` (not `map`) because the projection shouldn't crash
    /// if a stale id ever outlives its entry; in practice
    /// upsert-then-assign-ids on the same actor makes that unreachable.
    // SKIP @bridge
    public var feedStories: [Story] {
        feedIds.compactMap { id in
            hits[id].map { Story(hit: $0, isRead: readIds.contains(id)) }
        }
    }

    // SKIP @bridge
    public var searchResults: [Story] {
        searchIds.compactMap { id in
            hits[id].map { Story(hit: $0, isRead: readIds.contains(id)) }
        }
    }

    // SKIP @bridge
    public init() {
        let (stream, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.searchQueryChanges = stream
        self.searchQueryEvents = continuation
    }
}
