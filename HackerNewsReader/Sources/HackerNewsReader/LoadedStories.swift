import Foundation

/// Accumulated result of one or more page fetches against a paginated
/// listing — story ids in order, the pagination cursor, and a
/// freshness timestamp.
// SKIP @bridgeMembers
public struct LoadedStories: Sendable, Equatable {
    public var ids: [String]
    /// Timestamp of the most recent *initial* load.
    ///
    /// - Note: Not bumped by ``appendPage(_:totalPages:)``;
    ///   appending page 1 doesn't make page 0's rows any newer.
    public var loadedAt: Date
    public var page: Int
    public var totalPages: Int

    /// Whether another page is available to load.
    public var hasMore: Bool { page + 1 < totalPages }
    /// The next page index to request.
    public var nextPage: Int { page + 1 }

    /// Creates a loaded-stories value.
    ///
    /// - Parameters:
    ///   - ids: Story ids in display order.
    ///   - page: Zero-indexed current page.
    ///   - totalPages: Total page count reported by the transport.
    ///   - loadedAt: Time of the load; defaults to `Date()`.
    public init(ids: [String], page: Int, totalPages: Int, loadedAt: Date = Date()) {
        self.ids = ids
        self.page = page
        self.totalPages = totalPages
        self.loadedAt = loadedAt
    }

    /// Appends a page of ids and advances the cursor.
    ///
    /// - Parameters:
    ///   - newIds: Ids from the freshly fetched page.
    ///   - totalPages: Updated total page count from the transport.
    public mutating func appendPage(_ newIds: [String], totalPages: Int) {
        ids.append(contentsOf: newIds)
        page += 1
        self.totalPages = totalPages
    }
}
