import Foundation
import HackerNews

/// View row for a flattened Hacker News comment.
// SKIP @bridgeMembers
public struct CommentRow: Sendable, Identifiable, Equatable {
    public let id: String
    public let author: String
    public let text: String
    public let depth: Int
    public let metaLine: String

    // SKIP @nobridge — constructed on the Swift side; Kotlin reads
    // the materialised values.
    public init(comment: Comment, now: Date) {
        self.id = comment.id
        self.author = comment.author
        self.text = comment.text
        self.depth = comment.depth
        let age = presenterRelativeAge(from: comment.createdAt, to: now)
        self.metaLine = "by \(comment.author) · \(age)"
    }
}
