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
public struct LoadedHits: Sendable, Equatable {
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

/// Activity status for a single in-flight operation against a surface
/// (initial fetch / refresh, or load-more). Orthogonal to the data
/// result — `LoadableHits` holds two independent `LoadStatus` values
/// for its two axes so they can run concurrently.
///
/// `startLoading()` does **not** clear `error`. A stale banner
/// persists through a retry until either success clears it or another
/// failure replaces it.
// SKIP @bridgeMembers
public struct LoadStatus: Sendable, Equatable {
    public var isLoading: Bool
    public var error: String?

    public init(isLoading: Bool = false, error: String? = nil) {
        self.isLoading = isLoading
        self.error = error
    }

    public mutating func startLoading() {
        isLoading = true
    }

    public mutating func finishSuccess() {
        isLoading = false
        error = nil
    }

    public mutating func finishFailure(_ message: String) {
        isLoading = false
        error = message
    }
}

/// One paginated surface (feed or search) packaged with its loading
/// lifecycle: the accumulated `LoadedHits` plus two independent
/// `LoadStatus` values for first-page-load/refresh and load-more.
///
/// `loadedHits` and the two statuses are orthogonal axes — `loadedHits`
/// persists across `startLoading()` and `finishFailure()`, so the UI
/// shows stale data under a spinner or behind an error banner without
/// any explicit prev-payload threading.
// SKIP @bridgeMembers
public struct LoadableHits: Sendable, Equatable {
    public var loadedHits: LoadedHits?
    public var initialStatus: LoadStatus
    public var loadMoreStatus: LoadStatus

    public init(
        loadedHits: LoadedHits? = nil,
        initialStatus: LoadStatus = LoadStatus(),
        loadMoreStatus: LoadStatus = LoadStatus()
    ) {
        self.loadedHits = loadedHits
        self.initialStatus = initialStatus
        self.loadMoreStatus = loadMoreStatus
    }

    public mutating func receiveInitialPage(_ ids: [String], totalPages: Int, loadedAt: Date) {
        loadedHits = LoadedHits(ids: ids, page: 0, totalPages: totalPages, loadedAt: loadedAt)
        initialStatus.finishSuccess()
    }

    public mutating func receiveLoadMorePage(_ ids: [String], totalPages: Int) {
        loadedHits?.appendPage(ids, totalPages: totalPages)
        loadMoreStatus.finishSuccess()
    }
}
