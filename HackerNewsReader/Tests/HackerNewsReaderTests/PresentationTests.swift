import Foundation
import Testing
@testable import HackerNewsReader
import HackerNews

private let pinnedNow = Date(timeIntervalSince1970: 86_400)

private func makeStory(
    id: String = "1",
    author: String = "alice",
    score: Int = 42,
    commentCount: Int = 7,
    url: String? = "https://example.com/a",
    createdAt: Date = Date(timeIntervalSince1970: 0)
) -> Story {
    Story(
        id: id,
        title: "T",
        author: author,
        score: score,
        commentCount: commentCount,
        url: url,
        createdAt: createdAt
    )
}

private func makeRow(_ story: Story, isRead: Bool = false, now: Date = pinnedNow) -> StoryRow {
    StoryRow(story: story, isRead: isRead, now: now)
}

/// Pins `Dependencies.date` to `pinnedNow` for the duration of
/// `body` — every `Model.feedHeaderSubtitle` / `feedStories` read
/// inside sees the same reference time.
private func withPinnedNow<R>(_ body: () throws -> R) rethrows -> R {
    try Dependencies.$date.withValue(.constant(pinnedNow), operation: body)
}

@Suite("StoryRow presentation")
struct StoryRowPresentationTests {

    @Test("displayHost extracts the URL host")
    func displayHost_extractsHost() {
        let row = makeRow(makeStory(url: "https://github.com/foo/bar"))
        #expect(row.displayHost == "github.com")
    }

    @Test("displayHost falls back to news.ycombinator.com for self-posts")
    func displayHost_fallsBackForSelfPost() {
        let row = makeRow(makeStory(url: nil))
        #expect(row.displayHost == "news.ycombinator.com")
    }

    @Test("displayHost falls back when the URL fails to parse")
    func displayHost_fallsBackForUnparseable() {
        let row = makeRow(makeStory(url: "not a url"))
        #expect(row.displayHost == "news.ycombinator.com")
    }

    @Test("metaLine includes author, host, and pluralised score/comments")
    func metaLine_includesFields() {
        let row = makeRow(
            makeStory(author: "alice", score: 142, commentCount: 37, url: "https://github.com/x")
        )
        #expect(row.metaLine.contains("by alice"))
        #expect(row.metaLine.contains("142 points"))
        #expect(row.metaLine.contains("37 comments"))
        #expect(row.metaLine.contains("github.com"))
    }

    @Test("metaLine uses singular when score and comments are 1")
    func metaLine_singularForOne() {
        let row = makeRow(makeStory(score: 1, commentCount: 1))
        #expect(row.metaLine.contains(" 1 point "))
        #expect(row.metaLine.contains(" 1 comment "))
        #expect(!row.metaLine.contains("1 points"))
        #expect(!row.metaLine.contains("1 comments"))
    }

    @Test("readActionLabel flips on isRead")
    func readActionLabel_toggles() {
        #expect(makeRow(makeStory(), isRead: false).readActionLabel == "Mark Read")
        #expect(makeRow(makeStory(), isRead: true).readActionLabel == "Mark Unread")
    }
}

@Suite("Model.feedHeaderSubtitle")
struct FeedHeaderSubtitleTests {

    @Test("empty feed without feedLoaded reads 'never'")
    func empty_neverRefreshed() {
        withPinnedNow {
            let model = Model()
            #expect(model.feedHeaderSubtitle == "Last refreshed: never")
        }
    }

    @Test("empty feed with a feedLoaded timestamp shows that time")
    func empty_withRefreshTime() {
        withPinnedNow {
            let model = Model()
            model.feedLoaded = LoadedStories(
                ids: [],
                page: 0,
                totalPages: 1,
                loadedAt: Date(timeIntervalSince1970: 0)
            )
            let subtitle = model.feedHeaderSubtitle
            #expect(subtitle.hasPrefix("Last refreshed: "))
            #expect(!subtitle.contains("unread"))
        }
    }

    @Test("populated feed shows unread count of total + refresh stamp")
    func populated_unreadOfTotal() {
        withPinnedNow {
            let model = Model()
            model.stories = [
                "1": makeStory(id: "1"),
                "2": makeStory(id: "2"),
                "3": makeStory(id: "3"),
            ]
            model.readIds = ["2"]
            model.feedLoaded = LoadedStories(
                ids: ["1", "2", "3"],
                page: 0,
                totalPages: 1,
                loadedAt: Date(timeIntervalSince1970: 0)
            )

            let subtitle = model.feedHeaderSubtitle
            #expect(subtitle.contains("2 unread"))
            #expect(subtitle.contains("of 3"))
            #expect(subtitle.contains("last refreshed "))
        }
    }

    @Test("populated feed with one unread")
    func populated_singularUnread() {
        withPinnedNow {
            let model = Model()
            model.stories = [
                "1": makeStory(id: "1"),
                "2": makeStory(id: "2"),
            ]
            model.readIds = ["1"]
            model.feedLoaded = LoadedStories(
                ids: ["1", "2"],
                page: 0,
                totalPages: 1,
                loadedAt: Date(timeIntervalSince1970: 0)
            )

            let subtitle = model.feedHeaderSubtitle
            #expect(subtitle.contains("1 unread"))
            #expect(subtitle.contains("of 2"))
        }
    }
}

@Suite("Strings")
struct StringsTests {

    @Test("static accessors return their English defaults")
    func staticAccessors_returnEnglish() {
        #expect(Strings.appTitle == "Hacker News")
        #expect(Strings.feedTitle == "Front page")
        #expect(Strings.searchPlaceholder == "Search Hacker News")
        #expect(Strings.feedHeaderLastRefreshedNever == "never")
        #expect(Strings.loadingMore == "Loading more…")
        #expect(Strings.tryAgain == "Try again")
        #expect(Strings.commentsTitle == "Comments")
        #expect(Strings.commentsNoComments == "No comments")
        #expect(Strings.commentsMissingStory == "Story not found")
        #expect(Strings.openArticle == "Open Article")
    }

    @Test("searchHeader and searchNoResults interpolate the query")
    func interpolating_accessors() {
        #expect(Strings.searchHeader("swift") == "Searching for “swift”")
        #expect(Strings.searchNoResults("swift") == "No matching stories for “swift”")
    }

    @Test("markRead / markUnread are distinct constants")
    func mark_constants() {
        #expect(Strings.markRead == "Mark Read")
        #expect(Strings.markUnread == "Mark Unread")
    }
}
