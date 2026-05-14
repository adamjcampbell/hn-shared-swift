import Foundation

/// One page of Hacker News stories, paired with the total page count so
/// callers can drive a `hasMore` cursor without a second probe.
///
/// For the Firebase front-page transport, `totalPages` is synthesised
/// from the length of the `topstories.json` ID list divided by the page
/// size. For the Algolia search transport, it's the envelope's
/// `nbPages` field.
public struct Page: Sendable, Equatable {
    public let stories: [Story]
    public let totalPages: Int

    public init(stories: [Story], totalPages: Int) {
        self.stories = stories
        self.totalPages = totalPages
    }
}
