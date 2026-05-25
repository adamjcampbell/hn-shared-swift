import Foundation

/// A Hacker News comment flattened from the Firebase item tree.
// SKIP @bridgeMembers
public struct Comment: Sendable, Identifiable, Codable, Equatable {
    public let id: String
    public let author: String
    public let text: String
    public let createdAt: Date
    public let depth: Int

    /// Creates a comment from already-decoded field values.
    ///
    /// - Parameters:
    ///   - id: The HN comment id.
    ///   - author: Comment author username.
    ///   - text: Plain-text comment body.
    ///   - createdAt: Comment timestamp.
    ///   - depth: Nesting depth beneath the story root.
    public init(id: String, author: String, text: String, createdAt: Date, depth: Int) {
        self.id = id
        self.author = author
        self.text = text
        self.createdAt = createdAt
        self.depth = depth
    }
}
