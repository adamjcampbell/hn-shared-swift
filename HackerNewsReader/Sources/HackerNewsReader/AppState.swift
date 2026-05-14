import Foundation
import Observation
import HackerNews
import SkipFuse

/// The single source of truth for the example app.
///
/// `AppState` is an `@Observable final class` so SwiftUI's fine-grained
/// invalidation tracks property reads directly on iOS. On Android, SkipFuse
/// intercepts the same observation tracking and routes property
/// reads/mutations through Compose's snapshot system — reads inside a
/// `@Composable` are recorded, mutations trigger recomposition.
///
/// Stories are stored in a normalised dictionary keyed by id; the feed
/// and search surfaces project it through their own ordered id lists. A
/// story that appears in both surfaces is stored once, so toggle-read
/// flows to both projections through `readIds` without any cross-surface
/// sync.
// SKIP @bridgeMembers
@Observable
public final class AppState {

    // MARK: Stored sources of truth (public, bridged)

    /// `@Observable` drives reads-to-recompose (SwiftUI / Compose);
    /// `searchQueryChanges` drives the writes-to-fetch listener in
    /// `AppCore`. Two channels deliberately —
    /// trying to bridge them with a `withObservationTracking`-based
    /// iterator created an arm/disarm window where bursts of writes
    /// during a long `await` were silently dropped.
    public var searchQuery: String = "" {
        didSet { searchQueryEvents.yield(searchQuery) }
    }

    public var feed: LoadableStories = LoadableStories()
    public var search: LoadableStories = LoadableStories()

    // MARK: Stored sources of truth (internal)

    /// Entity store. Every fetch upserts the stories it returned — feed
    /// and search never clobber each other's entries. ~80 entries per
    /// session (front page + one search), so no pruning.
    var stories: [String: Story] = [:]
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
    /// if a stale id ever outlives its entry; in practice each fetch
    /// commits stories to the store before assigning ids on the same
    /// actor, so the lookup is total.
    public var feedStories: [StoryRow] {
        (feed.loadedStories?.ids ?? []).compactMap { id in
            stories[id].map { StoryRow(story: $0, isRead: readIds.contains(id)) }
        }
    }

    public var searchResults: [StoryRow] {
        (search.loadedStories?.ids ?? []).compactMap { id in
            stories[id].map { StoryRow(story: $0, isRead: readIds.contains(id)) }
        }
    }

    public init() {
        let (stream, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.searchQueryChanges = stream
        self.searchQueryEvents = continuation
    }
}
