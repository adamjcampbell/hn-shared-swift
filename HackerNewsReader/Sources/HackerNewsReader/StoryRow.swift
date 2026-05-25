import Foundation
import HackerNews

/// Pure-Swift relative-age bucket shared by presenter rows —
/// `Foundation.RelativeDateTimeFormatter` isn't bridged through
/// skip-foundation, so both platforms read this materialised value.
func presenterRelativeAge(from past: Date, to now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(past))
    if seconds < 60 { return "just now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    let days = hours / 24
    if days < 7 { return "\(days)d ago" }
    let weeks = days / 7
    if weeks < 52 { return "\(weeks)w ago" }
    return "\(days / 365)y ago"
}

/// View row — `Story` fields plus the per-user `isRead` flag projected
/// from `Model.readIds`, with presentation strings precomputed against
/// a `now` snapshot supplied by the projection.
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

    /// Host extracted from `url` for display. Self-posts (`url == nil`
    /// or an unparseable URL) fall back to `news.ycombinator.com`,
    /// matching the convention HN itself shows.
    public let displayHost: String

    /// Caption shown under the title — author, score, comment count,
    /// display host, and the story's age relative to the projection's
    /// `now`. Materialised at construction so the view consumes it as
    /// a property with no `Date.now` lookup of its own.
    public let metaLine: String

    /// Swipe-action label that flips on `isRead`.
    public let readActionLabel: String

    /// Projects a `Story` plus an `isRead` flag and a reference time
    /// into a row.
    ///
    /// - Parameters:
    ///   - story: Source story.
    ///   - isRead: Whether the user has opened this story.
    ///   - now: Reference time for the relative-age component.
    // SKIP @nobridge — constructed on the Swift side; Kotlin reads
    // the materialised values.
    public init(story: Story, isRead: Bool, now: Date) {
        self.id = story.id
        self.title = story.title
        self.author = story.author
        self.score = story.score
        self.commentCount = story.commentCount
        self.url = story.url
        self.createdAt = story.createdAt
        self.isRead = isRead

        let host = URL(string: story.url ?? "")?.host ?? "news.ycombinator.com"
        self.displayHost = host
        self.readActionLabel = isRead ? Strings.markUnread : Strings.markRead

        let age = presenterRelativeAge(from: story.createdAt, to: now)
        let scorePart = story.score == 1 ? "1 point" : "\(story.score) points"
        let commentPart = story.commentCount == 1 ? "1 comment" : "\(story.commentCount) comments"
        self.metaLine = "by \(story.author) · \(scorePart) · \(commentPart) · \(host) · \(age)"
    }
}
