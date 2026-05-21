import Foundation
import Observation
import HackerNews
import SkipFuse

/// Source of truth for the app — observable state for the feed,
/// search, and read-tracking surfaces.
///
/// Stories live in one normalised `[id: Story]` dictionary; the feed
/// and search surfaces project that store through their own ordered
/// id lists, so a story shared by both surfaces is stored once and a
/// toggle of `readIds` reaches both projections without sync. The
/// `@Observable` conformance gives SwiftUI fine-grained per-property
/// tracking on iOS; SkipFuse routes the same tracking through
/// Compose's snapshot system on Android.
///
/// Setter visibility encodes data-flow direction: `public var` is a
/// two-way field that the UI binds and writes back (currently only
/// ``searchQuery``); `public internal(set) var` is one-way, written
/// by `Engine` and read by the UI.
// SKIP @bridgeMembers
@Observable
public final class Model {

    // MARK: Search input

    /// Current search query. Driven directly from both platforms;
    /// every write echoes into `searchQueryChanges` for `Engine`'s
    /// fetch listener.
    public var searchQuery: String = "" {
        didSet { searchQueryEvents.yield(searchQuery) }
    }

    // MARK: Feed surface — three flat axes

    public internal(set) var feedLoaded: LoadedStories? = nil
    public internal(set) var feedInitialStatus: LoadStatus = LoadStatus()
    public internal(set) var feedLoadMoreStatus: LoadStatus = LoadStatus()

    // MARK: Search surface — mirrored

    public internal(set) var searchLoaded: LoadedStories? = nil
    public internal(set) var searchInitialStatus: LoadStatus = LoadStatus()
    public internal(set) var searchLoadMoreStatus: LoadStatus = LoadStatus()

    // MARK: Entity store (internal)

    /// Normalised entity store; both surfaces project ids through it.
    var stories: [String: Story] = [:]
    var readIds: Set<String> = []

    // MARK: searchQuery event stream

    /// Stream of ``searchQuery`` writes; `bufferingNewest(1)` so a
    /// slow consumer sees only the latest value.
    let searchQueryChanges: AsyncStream<String>
    private let searchQueryEvents: AsyncStream<String>.Continuation

    // MARK: Derived view rows

    /// View rows for the feed — ids resolved against `stories` and
    /// tagged with `readIds`. The reference time is captured once per
    /// access from `Dependencies.date` so a row's `metaLine` is
    /// consistent within one snapshot; tests override via
    /// `Dependencies.$date.withValue(.constant(_:))`.
    public var feedStories: [StoryRow] { project(ids: feedLoaded?.ids) }

    public var searchResults: [StoryRow] { project(ids: searchLoaded?.ids) }

    private func project(ids: [String]?) -> [StoryRow] {
        let now = Dependencies.date.now
        return (ids ?? []).compactMap { id in
            stories[id].map { StoryRow(story: $0, isRead: readIds.contains(id), now: now) }
        }
    }

    // MARK: Derived presentation

    /// Caption under `Front page` — unread/total counts plus the time
    /// of the most recent refresh. Reads `feedStories` (via the
    /// projection above), so `@Observable` tracking refires on any
    /// change to ``feedLoaded``, the entity store, or ``readIds``.
    public var feedHeaderSubtitle: String {
        let stamp: String = (feedLoaded?.loadedAt).map {
            $0.formatted(date: .omitted, time: .standard)
        } ?? Strings.feedHeaderLastRefreshedNever

        let rows = feedStories
        let total = rows.count
        if total == 0 {
            return Strings.feedHeaderRefreshedOnly(stamp)
        }
        let unread = rows.lazy.filter { !$0.isRead }.count
        return Strings.feedHeaderUnreadOfTotal(unread, total, stamp)
    }

    public init() {
        let (stream, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.searchQueryChanges = stream
        self.searchQueryEvents = continuation
    }
}
