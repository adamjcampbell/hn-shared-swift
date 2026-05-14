import Foundation
import HackerNews

/// View row: the API `Story` fields plus the per-user `isRead` flag,
/// projected from `AppState.readIds` at read time. Constructed by
/// `AppState.feedStories` / `AppState.searchResults` from the stored
/// `[String: Story]` entity dictionary + `readIds`. SkipFuse bridges
/// `StoryRow` to Kotlin as a peer-backed class; `// SKIP @bridgeMembers`
/// exposes every public field as a Kotlin property getter that JNI-calls
/// back into the Swift struct. The init is opted out (`// SKIP @nobridge`)
/// because rows are constructed on the Swift side from `AppState`'s
/// projections; Kotlin never builds one directly.
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
