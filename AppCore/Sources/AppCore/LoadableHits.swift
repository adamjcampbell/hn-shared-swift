import Foundation

/// The accumulated result of one or more page fetches against a
/// paginated Hacker News listing — story ids in order, the pagination
/// cursor, and a freshness timestamp.
///
/// `loadedAt` is the time of the most recent **initial** load. It is
/// intentionally not bumped when subsequent pages are appended: the
/// user-facing meaning is "how stale is this feed", and appending
/// page 1 doesn't make page 0's rows any newer.
// SKIP @bridge
public struct LoadedHits: Sendable, Equatable {
    // SKIP @bridge
    public var ids: [String]
    // SKIP @bridge
    public var loadedAt: Date
    // SKIP @bridge
    public var page: Int
    // SKIP @bridge
    public var totalPages: Int

    // SKIP @bridge
    public var hasMore: Bool { page + 1 < totalPages }
    // SKIP @bridge
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
// SKIP @bridge
public struct LoadStatus: Sendable, Equatable {
    // SKIP @bridge
    public var isLoading: Bool
    // SKIP @bridge
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
// SKIP @bridge
public struct LoadableHits: Sendable, Equatable {
    // SKIP @bridge
    public var loadedHits: LoadedHits?
    // SKIP @bridge
    public var initialStatus: LoadStatus
    // SKIP @bridge
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

    public mutating func receiveInitialPage(_ ids: [String], totalPages: Int) {
        loadedHits = LoadedHits(ids: ids, page: 0, totalPages: totalPages)
        initialStatus.finishSuccess()
    }

    public mutating func receiveLoadMorePage(_ ids: [String], totalPages: Int) {
        loadedHits?.appendPage(ids, totalPages: totalPages)
        loadMoreStatus.finishSuccess()
    }
}
