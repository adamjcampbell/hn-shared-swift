import Foundation

/// A Hacker News story hit as returned by the Algolia HN search API
/// (`hn.algolia.com/api/v1`). The `id` is Algolia's `objectID` —
/// numeric in practice, but kept as `String` because that's what the
/// API returns.
///
/// `HNHit` is the canonical *entity*: what the API gave us, with no
/// per-user state. `Story` (below) is the *view row* — the same fields
/// plus `isRead`, materialised by `AppState.stories` from `HNHit` +
/// `AppState.readIds`. UIs only ever see `Story`.
public struct HNHit: Sendable, Identifiable, Codable, Equatable {
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

/// View row: `HNHit` fields plus the per-user `isRead` flag, projected
/// from `AppState.readIds` at read time. Constructed by `AppState.stories`
/// and emitted on the wire to Android with `isRead` already merged in.
public struct Story: Sendable, Identifiable, Codable, Equatable {
    public let id: String
    public let title: String
    public let author: String
    public let points: Int
    public let commentCount: Int
    public let url: String?
    public let createdAt: Date
    public let isRead: Bool

    public init(hit: HNHit, isRead: Bool) {
        self.id = hit.id
        self.title = hit.title
        self.author = hit.author
        self.points = hit.points
        self.commentCount = hit.commentCount
        self.url = hit.url
        self.createdAt = hit.createdAt
        self.isRead = isRead
    }
}
