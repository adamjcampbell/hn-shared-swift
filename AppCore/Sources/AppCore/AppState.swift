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
    public var feed: LoadableHits = LoadableHits()
    // SKIP @bridge
    public var search: LoadableHits = LoadableHits()

    // MARK: Stored sources of truth (internal)

    /// Entity store. Every fetch upserts the hits it returned — feed
    /// and search never clobber each other's entries. ~80 entries per
    /// session (front page + one search), so no pruning.
    var hits: [String: HNHit] = [:]
    var readIds: Set<String> = []

    // MARK: searchQuery event stream

    /// `.bufferingNewest(1)` collapses bursts during a slow consumer
    /// (e.g. a fetch parked in debounce + network) to a single emission
    /// of the final value — matches the debounce/settle semantics.
    /// `yield` is synchronous and non-blocking.
    let searchQueryChanges: AsyncStream<String>
    private let searchQueryEvents: AsyncStream<String>.Continuation

    // MARK: Derived view rows

    /// `compactMap` (not `map`) because the projection shouldn't crash
    /// if a stale id ever outlives its entry; in practice
    /// upsert-then-assign-ids on the same actor makes that unreachable.
    // SKIP @bridge
    public var feedStories: [Story] {
        (feed.loadedHits?.ids ?? []).compactMap { id in
            hits[id].map { Story(hit: $0, isRead: readIds.contains(id)) }
        }
    }

    // SKIP @bridge
    public var searchResults: [Story] {
        (search.loadedHits?.ids ?? []).compactMap { id in
            hits[id].map { Story(hit: $0, isRead: readIds.contains(id)) }
        }
    }

    // MARK: Mutators

    /// Upsert a page's hits into the entity store and return the ids in
    /// page order. Every fetch-success commit needs both halves — having
    /// them in one place keeps the projection ids in sync with the
    /// entity store automatically.
    @discardableResult
    func upsert(_ page: HNPage) -> [String] {
        for hit in page.hits { hits[hit.id] = hit }
        return page.hits.map(\.id)
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
