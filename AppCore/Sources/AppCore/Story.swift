import Foundation

/// A Hacker News story as exposed by the Algolia HN search API
/// (`hn.algolia.com/api/v1`). The `id` is Algolia's `objectID` —
/// numeric in practice, but kept as `String` because that's what the
/// API returns.
public struct Story: Sendable, Identifiable, Codable, Equatable {
    public let id: String
    public let title: String
    public let author: String
    public let points: Int
    public let commentCount: Int
    public let url: String?
    public let createdAt: Date

    public init(
        id: String,
        title: String,
        author: String,
        points: Int,
        commentCount: Int,
        url: String?,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.points = points
        self.commentCount = commentCount
        self.url = url
        self.createdAt = createdAt
    }
}
