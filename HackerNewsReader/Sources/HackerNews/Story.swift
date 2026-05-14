import Foundation

/// A Hacker News story. The canonical entity returned by the official
/// Firebase HN API at `hacker-news.firebaseio.com/v0` (front-page feed)
/// and the Algolia HN search API at `hn.algolia.com/api/v1` (text
/// search). Both transports normalise into this shape.
///
/// The `id` is the story's numeric HN ID, kept as `String` because
/// Algolia surfaces it as `objectID` (string) and we don't gain anything
/// from converting twice on the bridge.
///
/// `score` matches both APIs' vocabulary (Firebase: `score`, HN UI:
/// "points"). Other fields favour the more descriptive Swift names
/// (`author`, `commentCount`, `createdAt`) over the terser Firebase
/// originals (`by`, `descendants`, `time`).
// SKIP @bridgeMembers
public struct Story: Sendable, Identifiable, Codable, Equatable {
    public let id: String
    public let title: String
    public let author: String
    public let score: Int
    public let commentCount: Int
    public let url: String?
    public let createdAt: Date

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
