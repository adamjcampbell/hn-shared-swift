import Foundation

/// A Hacker News story — the canonical entity normalised from both
/// the Firebase front-page feed and the Algolia search results.
// SKIP @bridgeMembers
public struct Story: Sendable, Identifiable, Codable, Equatable {
    public let id: String
    public let title: String
    public let author: String
    /// HN points; both APIs surface this as the upvote score.
    public let score: Int
    public let commentCount: Int
    public let url: String?
    public let createdAt: Date

    /// Creates a story from already-decoded field values.
    ///
    /// - Parameters:
    ///   - id: The HN story id (string so Algolia's `objectID` and
    ///     Firebase's numeric id share one shape).
    ///   - title: Headline text.
    ///   - author: Submitter username.
    ///   - score: HN points.
    ///   - commentCount: Number of descendant comments.
    ///   - url: Submitted link, or `nil` for self-posts.
    ///   - createdAt: Submission timestamp.
    public init(
        id: String,
        title: String,
        author: String,
        score: Int,
        commentCount: Int,
        url: String?,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.score = score
        self.commentCount = commentCount
        self.url = url
        self.createdAt = createdAt
    }
}
