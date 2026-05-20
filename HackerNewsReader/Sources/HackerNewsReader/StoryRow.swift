import Foundation
import HackerNews

/// View row — `Story` fields plus the per-user `isRead` flag
/// projected from `Model.readIds`.
// SKIP @bridgeMembers
public struct StoryRow: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let author: String
    public let score: Int
    public let commentCount: Int
    public let url: String?
    public let createdAt: Date
    public let isRead: Bool

    /// Projects a `Story` plus an `isRead` flag into a row.
    ///
    /// - Parameters:
    ///   - story: Source story.
    ///   - isRead: Whether the user has opened this story.
    // SKIP @nobridge — constructed on the Swift side from a `Story` +
    // `isRead`; Kotlin reads the materialised value.
    public init(story: Story, isRead: Bool) {
        self.id = story.id
        self.title = story.title
        self.author = story.author
        self.score = story.score
        self.commentCount = story.commentCount
        self.url = story.url
        self.createdAt = story.createdAt
        self.isRead = isRead
    }
}
