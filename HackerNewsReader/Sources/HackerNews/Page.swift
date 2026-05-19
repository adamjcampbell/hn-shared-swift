import Foundation

/// One page of Hacker News stories alongside the total page count so
/// callers can drive a `hasMore` cursor without a second probe.
public struct Page: Sendable, Equatable {
    public let stories: [Story]
    public let totalPages: Int

    /// Creates a page.
    ///
    /// - Parameters:
    ///   - stories: Decoded stories for this page, in display order.
    ///   - totalPages: Total page count across the underlying listing.
    public init(stories: [Story], totalPages: Int) {
        self.stories = stories
        self.totalPages = totalPages
    }
}
