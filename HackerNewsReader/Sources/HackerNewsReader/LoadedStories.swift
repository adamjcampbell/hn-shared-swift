import Foundation

/// The accumulated result of one or more page fetches against a
/// paginated Hacker News listing — story ids in order, the pagination
/// cursor, and a freshness timestamp.
///
/// `loadedAt` is the time of the most recent **initial** load. It is
/// intentionally not bumped when subsequent pages are appended: the
/// user-facing meaning is "how stale is this feed", and appending
/// page 1 doesn't make page 0's rows any newer.
// SKIP @bridgeMembers
public struct LoadedStories: Sendable, Equatable {
    public var ids: [String]
    public var loadedAt: Date
    public var page: Int
    public var totalPages: Int

    public var hasMore: Bool { page + 1 < totalPages }
    public var nextPage: Int { page + 1 }

    public init(ids: [String], page: Int, totalPages: Int, loadedAt: Date = Date()) {
        self.ids = ids
        self.page = page
        self.totalPages = totalPages
        self.loadedAt = loadedAt
    }

    public mutating func appendPage(_ newIds: [String], totalPages: Int) {
        ids.append(contentsOf: newIds)
        page += 1
        self.totalPages = totalPages
    }
}
