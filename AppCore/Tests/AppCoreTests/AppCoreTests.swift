import Clocks
import Foundation
import Testing
@testable import AppCore

private let storyA = HNHit(
    id: "100", title: "Top story", author: "alice",
    points: 50, commentCount: 10,
    url: "https://example.com/a",
    createdAt: Date(timeIntervalSince1970: 1)
)
private let storyB = HNHit(
    id: "101", title: "Second story", author: "bob",
    points: 20, commentCount: 3,
    url: nil,
    createdAt: Date(timeIntervalSince1970: 2)
)
private let storyC = HNHit(
    id: "102", title: "Page-1 story", author: "carol",
    points: 9, commentCount: 1,
    url: "https://example.com/c",
    createdAt: Date(timeIntervalSince1970: 3)
)

/// Records the queries (and pages) the mock client was called with. An
/// actor so the `@Sendable` closures in the mock can mutate it from the
/// Task's executor while the test reads it from MainActor.
private actor CallRecorder {
    private(set) var frontPageCalls: [Int] = []
    private(set) var searchCalls: [(String, Int)] = []

    func recordFrontPage(page: Int) { frontPageCalls.append(page) }
    func recordSearch(_ query: String, page: Int) { searchCalls.append((query, page)) }
}

/// Test fixture for `TestCore` with optional `HNClient` mocks and an
/// injected clock. Defaults give an empty front page and an empty
/// search — override the relevant closure to express the test's intent.
private func makeCore(
    frontPage: @escaping @Sendable (Int) async throws -> HNPage = { _ in HNPage(hits: [], totalPages: 0) },
    search: @escaping @Sendable (String, Int) async throws -> HNPage = { _, _ in HNPage(hits: [], totalPages: 0) },
    clock: any Clock<Duration> = ContinuousClock()
) -> TestCore {
    TestCore(
        client: HNClient(frontPage: frontPage, search: search),
        clock: clock
    )
}

/// Convenience: a single-page response.
private func page(_ hits: [HNHit], totalPages: Int = 1) -> HNPage {
    HNPage(hits: hits, totalPages: totalPages)
}

@Suite("AppCore")
struct AppCoreTests {

    @Test("refresh populates feed stories and timestamp")
    func refresh_populatesStoriesAndTimestamp() async {
        let core = makeCore(frontPage: { _ in page([storyA, storyB]) })

        #expect(await core.feedStories.isEmpty)
        #expect(await core.feed.loadedHits == nil)

        await core.dispatch(.refresh)

        #expect(await core.feedStories.count == 2)
        #expect(await core.feedStories.first?.title == "Top story")
        #expect(await core.feed.loadedHits?.loadedAt != nil)
        #expect(await core.feed.initialStatus.error == nil)
    }

    @Test("refresh records initialStatus.error on failure")
    func refresh_recordsErrorOnFailure() async {
        struct Boom: Error {}
        let core = makeCore(
            frontPage: { _ in throw Boom() },
            search: { _, _ in throw Boom() }
        )

        await core.dispatch(.refresh)

        #expect(await core.feedStories.isEmpty)
        #expect(await core.feed.initialStatus.error != nil)
    }

    @Test("toggleRead adds and removes")
    func toggleRead_addsAndRemoves() async {
        let core = makeCore(frontPage: { _ in page([storyA]) })
        await core.dispatch(.refresh)
        #expect(await core.feedStories.first?.isRead == false)

        await core.dispatch(.toggleRead(id: storyA.id))
        #expect(await core.feedStories.first?.isRead == true)
        #expect(await core.readIds.contains(storyA.id))

        await core.dispatch(.toggleRead(id: storyA.id))
        #expect(await core.feedStories.first?.isRead == false)
        #expect(await core.readIds.contains(storyA.id) == false)
    }

    @Test("openStory marks read and emits presentURL command")
    func openStory_marksReadAndEmitsPresentURL() async {
        let core = makeCore(frontPage: { _ in page([storyA, storyB]) })
        await core.dispatch(.refresh)

        var iterator = core.commands.makeAsyncIterator()
        await core.dispatch(.openStory(id: storyA.id))

        #expect(await core.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("openStory on a story without a URL marks read but emits nothing")
    func openStory_withoutURL_marksReadOnly() async {
        let core = makeCore(frontPage: { _ in page([storyA, storyB]) })
        await core.dispatch(.refresh)

        // Open storyB (no URL) then storyA (has URL). The first emission
        // we observe is storyA's — proving storyB emitted nothing.
        var iterator = core.commands.makeAsyncIterator()
        await core.dispatch(.openStory(id: storyB.id))
        await core.dispatch(.openStory(id: storyA.id))

        #expect(await core.feedStories.first(where: { $0.id == storyB.id })?.isRead == true)
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("openStory with unknown id is a no-op")
    func openStory_unknownId_isNoop() async {
        let core = makeCore(frontPage: { _ in page([storyA]) })
        await core.dispatch(.refresh)
        let readBefore = await core.readIds

        var iterator = core.commands.makeAsyncIterator()
        await core.dispatch(.openStory(id: "does-not-exist"))
        await core.dispatch(.openStory(id: storyA.id))

        #expect(await core.readIds == readBefore.union([storyA.id]))
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("read state survives a refresh")
    func toggleRead_survivesRefresh() async {
        let core = makeCore(frontPage: { _ in page([storyA, storyB]) })
        // Toggle before any stories are loaded — readIds is the canonical
        // record; the projection has nothing to map onto yet.
        await core.dispatch(.toggleRead(id: "100"))
        #expect(await core.readIds.contains("100"))
        #expect(await core.feedStories.isEmpty)

        await core.dispatch(.refresh)
        let projected = await core.feedStories.first(where: { $0.id == "100" })
        #expect(projected != nil)
        #expect(projected?.isRead == true)
    }

    @Test("runSearchFetch debounces and fires search with current query")
    func runSearchFetch_debouncesAndFires() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let core = makeCore(
            search: { query, p in
                await calls.recordSearch(query, page: p)
                return page([storyA])
            },
            clock: clock
        )

        await core.with { $0.searchQuery = "rust" }
        let fetch = Task { [core] in
            await core.runSearchFetch(query: "rust", debounce: TestCore.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: TestCore.searchDebounce)
        await fetch.value

        #expect(await core.searchQuery == "rust")
        #expect(await core.searchResults.map(\.id) == ["100"])
        let recorded = await calls.searchCalls
        #expect(recorded.map(\.0) == ["rust"])
        #expect(recorded.map(\.1) == [0])
    }

    @Test("initialStatus.isLoading activates on first keystroke, before debounce elapses")
    func isSearchLoading_activatesOnFirstKeystroke() async {
        let clock = TestClock()
        let core = makeCore(search: { _, _ in page([storyA]) }, clock: clock)

        #expect(await core.search.initialStatus.isLoading == false)

        let fetch = Task { [core] in
            await core.runSearchFetch(query: "r", debounce: TestCore.searchDebounce)
        }
        await Task.megaYield()

        // Spinner asserted synchronously on entry, before the debounce.
        #expect(await core.search.initialStatus.isLoading == true)

        await clock.advance(by: TestCore.searchDebounce)
        await fetch.value

        #expect(await core.search.initialStatus.isLoading == false)
    }

    @Test("rapid runSearchFetch calls coalesce — only the latest fires")
    func runSearchFetch_coalescesRapidKeystrokes() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let core = makeCore(
            search: { query, p in
                await calls.recordSearch(query, page: p)
                return page([storyA])
            },
            clock: clock
        )

        // Three back-to-back keystrokes; each runSearchFetch cancels the
        // prior in-flight searchTask, so only the latest query fires.
        await core.with { $0.searchQuery = "ru" }
        let t1 = Task { [core] in
            await core.runSearchFetch(query: "ru", debounce: TestCore.searchDebounce)
        }
        await Task.megaYield()
        await core.with { $0.searchQuery = "rus" }
        let t2 = Task { [core] in
            await core.runSearchFetch(query: "rus", debounce: TestCore.searchDebounce)
        }
        await Task.megaYield()
        await core.with { $0.searchQuery = "rust" }
        let t3 = Task { [core] in
            await core.runSearchFetch(query: "rust", debounce: TestCore.searchDebounce)
        }
        await Task.megaYield()

        await clock.advance(by: TestCore.searchDebounce)
        await t1.value
        await t2.value
        await t3.value

        let recorded = await calls.searchCalls
        #expect(recorded.map(\.0) == ["rust"])
        #expect(await core.searchQuery == "rust")
        #expect(await core.searchResults.map(\.id) == ["100"])
    }

    @Test("refresh while a search is in flight re-runs the current search, not the feed")
    func refresh_whileSearching_reRunsSearch() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let core = makeCore(
            frontPage: { p in
                await calls.recordFrontPage(page: p)
                return page([storyA, storyB])
            },
            search: { query, p in
                await calls.recordSearch(query, page: p)
                return page([storyA])
            },
            clock: clock
        )

        await core.with { $0.searchQuery = "rust" }
        let pending = Task { [core] in
            await core.runSearchFetch(query: "rust", debounce: TestCore.searchDebounce)
        }
        await Task.megaYield()

        // .refresh with non-empty searchQuery re-runs the search; the
        // pending fetch is cancelled before it issues its own request.
        await core.dispatch(.refresh)
        await clock.advance(by: TestCore.searchDebounce)
        await pending.value

        let frontPageCalls = await calls.frontPageCalls
        let searchCalls = await calls.searchCalls
        #expect(frontPageCalls.isEmpty)
        #expect(searchCalls.map(\.0) == ["rust"])
        #expect(await core.searchResults.map(\.id) == ["100"])
    }


    @Test("URLError(.cancelled) from a cancelled feed fetch is treated as cancellation")
    func cancelledURLError_doesNotSurfaceAsFeedLoadError() async {
        // URLSession surfaces task cancellation as URLError.cancelled,
        // not Swift's CancellationError. Without the in-Task
        // normalisation, the dispatch arm's generic `catch` would write
        // `feed.initialStatus.error = "cancelled"`.
        let core = makeCore(
            frontPage: { _ in throw URLError(.cancelled) },
            search:    { _, _ in throw URLError(.cancelled) }
        )

        await core.dispatch(.refresh)

        #expect(await core.feed.initialStatus.error == nil)
        #expect(await core.feed.loadedHits == nil)
    }

    @Test("search-to-search cancel-and-replace through URLError(.cancelled) doesn't surface")
    func searchCancelAndReplace_throughURLErrorCancelled_silent() async {
        // Without the URLError → CancellationError normalisation, the
        // prior dispatch's catch arm would write
        // `search.initialStatus.error = "cancelled"` until the new
        // fetch settled.
        let clock = TestClock()
        let core = makeCore(
            search: { query, _ in
                if query == "ru" {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    throw URLError(.cancelled)
                }
                return page([storyA])
            },
            clock: clock
        )

        await core.with { $0.searchQuery = "ru" }
        let firstSearch = Task { [core] in
            await core.runSearchFetch(query: "ru", debounce: TestCore.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: TestCore.searchDebounce)
        await Task.megaYield()

        await core.with { $0.searchQuery = "rust" }
        let secondSearch = Task { [core] in
            await core.runSearchFetch(query: "rust", debounce: TestCore.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: TestCore.searchDebounce)

        await firstSearch.value
        await secondSearch.value

        #expect(await core.search.initialStatus.error == nil)
        #expect(await core.searchQuery == "rust")
        #expect(await core.searchResults.map(\.id) == ["100"])
    }

    @Test("clearing the search query cancels the search, clears results, and does not refetch the feed")
    func clearingSearchQuery_cancelsAndClearsResults() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let core = makeCore(
            frontPage: { p in
                await calls.recordFrontPage(page: p)
                return page([storyA, storyB])
            },
            search: { query, p in
                await calls.recordSearch(query, page: p)
                return page([storyA])
            },
            clock: clock
        )

        await core.dispatch(.refresh)
        let feedBefore = await core.feedStories.map(\.id)
        let frontPageBefore = await calls.frontPageCalls.count

        await core.with { $0.searchQuery = "rust" }
        let search = Task { [core] in
            await core.runSearchFetch(query: "rust", debounce: TestCore.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: TestCore.searchDebounce)
        await search.value
        #expect(await core.searchResults.map(\.id) == ["100"])

        await core.with { $0.searchQuery = "" }
        await core.clearSearch()

        #expect(await core.searchResults.isEmpty)
        #expect(await core.search.initialStatus.error == nil)
        #expect(await core.search.initialStatus.isLoading == false)
        #expect(await core.search.loadedHits == nil)
        #expect(await core.feedStories.map(\.id) == feedBefore)
        let frontPageAfter = await calls.frontPageCalls.count
        #expect(frontPageAfter == frontPageBefore)
        let searchCalls = await calls.searchCalls
        #expect(searchCalls.map(\.0) == ["rust"])
    }

    @Test("feed survives an active search")
    func feedSurvivesActiveSearch() async {
        let clock = TestClock()
        let core = makeCore(
            frontPage: { _ in page([storyA, storyB]) },
            search: { _, _ in page([storyA]) },
            clock: clock
        )

        await core.dispatch(.refresh)
        let feedSnapshot = await core.feedStories.map(\.id)
        #expect(feedSnapshot == ["100", "101"])

        await core.with { $0.searchQuery = "x" }
        let search = Task { [core] in
            await core.runSearchFetch(query: "x", debounce: TestCore.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: TestCore.searchDebounce)
        await search.value

        #expect(await core.searchResults.map(\.id) == ["100"])
        #expect(await core.feedStories.map(\.id) == feedSnapshot)
    }

    @Test("backspacing all the way to empty during an in-flight fetch still clears results")
    func listener_burstWriteDuringFetchClearsResults() async {
        // Regression: burst writes during an in-flight fetch must still
        // clear results when the final value is empty. The internal
        // listener schedules "rust" (parked in the debounce sleep),
        // then immediately consumes the empty write, which calls
        // `clearSearch()` and cancels the parked task before its
        // network call fires — so zero recorded calls.
        let calls = CallRecorder()
        let clock = TestClock()
        let core = makeCore(
            search: { query, p in
                await calls.recordSearch(query, page: p)
                return page([storyA])
            },
            clock: clock
        )

        // Let the listener spawned in `AppCore.bootstrap` reach
        // its `for await` suspension point before the first write.
        await Task.megaYield()

        // Listener reads "rust" and schedules a search task that parks
        // in the debounce sleep.
        await core.with { $0.searchQuery = "rust" }
        await Task.megaYield()

        // Backspace to empty. The non-blocking listener consumes this
        // immediately and calls `clearSearch()`, cancelling the parked
        // task before it reaches the network.
        await core.with { $0.searchQuery = "" }
        await Task.megaYield()

        await clock.advance(by: TestCore.searchDebounce)
        await Task.megaYield()

        #expect(await core.searchResults.isEmpty)
        #expect(await core.search.initialStatus.error == nil)
        #expect(await core.search.initialStatus.isLoading == false)
        let recorded = await calls.searchCalls
        #expect(recorded.map(\.0) == [])

        await core.shutdown()
    }

    @Test("rapid keystrokes within the debounce window collapse to one search")
    func listener_rapidKeystrokes_onlyFinalQueryFires() async {
        // Regression: typing "rust" quickly used to produce two result
        // sets — the pre-fix watcher's `for await` blocked on the first
        // fetch's debounce, so "r" fired before the rest collapsed via
        // `.bufferingNewest(1)`. With the non-blocking listener, each
        // keystroke schedules a new task that cancels the prior in its
        // debounce sleep — only "rust" reaches the network.
        let calls = CallRecorder()
        let clock = TestClock()
        let core = makeCore(
            search: { query, p in
                await calls.recordSearch(query, page: p)
                return page([storyA])
            },
            clock: clock
        )

        // Let the listener spawned in `AppCore.bootstrap` reach
        // its `for await` suspension point before the first write.
        await Task.megaYield()

        await core.with { $0.searchQuery = "r" }
        await Task.megaYield()
        await core.with { $0.searchQuery = "ru" }
        await Task.megaYield()
        await core.with { $0.searchQuery = "rust" }
        await Task.megaYield()

        await clock.advance(by: TestCore.searchDebounce)
        await Task.megaYield()

        let recorded = await calls.searchCalls
        #expect(recorded.map(\.0) == ["rust"])
        #expect(await core.searchResults.map(\.id) == ["100"])

        await core.shutdown()
    }

    @Test("a story present in both feed and search shares its read state across projections")
    func storyInBothFeedAndSearch_sharesReadState() async {
        let clock = TestClock()
        let core = makeCore(
            frontPage: { _ in page([storyA, storyB]) },
            search: { _, _ in page([storyA]) },
            clock: clock
        )

        await core.dispatch(.refresh)
        await core.dispatch(.toggleRead(id: storyA.id))
        #expect(await core.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)

        await core.with { $0.searchQuery = "x" }
        let search = Task { [core] in
            await core.runSearchFetch(query: "x", debounce: TestCore.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: TestCore.searchDebounce)
        await search.value

        #expect(await core.searchResults.first?.isRead == true)
    }

    // MARK: Pagination

    @Test("loadMore appends page-1 ids to the snapshot and bumps the cursor")
    func loadMore_appendsAndBumpsCursor() async {
        let core = makeCore(
            frontPage: { p in
                if p == 0 { return page([storyA, storyB], totalPages: 3) }
                if p == 1 { return page([storyC], totalPages: 3) }
                return page([])
            }
        )

        await core.dispatch(.refresh)
        #expect(await core.feed.loadedHits?.page == 0)
        #expect(await core.feed.loadedHits?.hasMore == true)
        #expect(await core.feedStories.map(\.id) == ["100", "101"])

        await core.dispatch(.loadMore)
        #expect(await core.feed.loadedHits?.page == 1)
        #expect(await core.feed.loadedHits?.hasMore == true)  // page 1 of 3, page 2 still remains
        #expect(await core.feedStories.map(\.id) == ["100", "101", "102"])
    }

    @Test("loadMore on the last page is a no-op")
    func loadMore_onLastPage_isNoop() async {
        let calls = CallRecorder()
        let core = makeCore(
            frontPage: { p in
                await calls.recordFrontPage(page: p)
                return page([storyA], totalPages: 1)
            }
        )

        await core.dispatch(.refresh)
        #expect(await core.feed.loadedHits?.hasMore == false)

        await core.dispatch(.loadMore)
        let pages = await calls.frontPageCalls
        #expect(pages == [0])  // only the initial fetch
    }

    @Test("loadMore before any initial fetch is a no-op")
    func loadMore_withoutInitial_isNoop() async {
        let calls = CallRecorder()
        let core = makeCore(
            frontPage: { p in
                await calls.recordFrontPage(page: p)
                return page([storyA])
            }
        )

        await core.dispatch(.loadMore)
        let pages = await calls.frontPageCalls
        #expect(pages.isEmpty)
    }

    @Test("refresh during an in-flight loadMore cancels the loadMore")
    func refresh_duringLoadMore_cancelsLoadMore() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let core = makeCore(
            frontPage: { p in
                await calls.recordFrontPage(page: p)
                if p == 1 {
                    // Park in a cancellable sleep so the refresh has time
                    // to cancel us before we return.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    throw CancellationError()
                }
                return page([storyA], totalPages: 5)
            },
            clock: clock
        )

        await core.dispatch(.refresh)  // page 0 lands
        #expect(await core.feed.loadedHits?.page == 0)

        let loadMore = Task { [core] in
            await core.runFeedLoadMore()
        }
        await Task.megaYield()
        #expect(await core.feed.loadMoreStatus.isLoading == true)

        // Refresh while page-1 is parked. Refresh's first action is
        // `tasks[.feedMore] = nil`, which cancels the parked task.
        await core.dispatch(.refresh)
        await loadMore.value

        // page resets to 0 after refresh; loadMore status cleared.
        #expect(await core.feed.loadedHits?.page == 0)
        #expect(await core.feed.loadMoreStatus.isLoading == false)
        #expect(await core.feed.loadMoreStatus.error == nil)
    }

    @Test("loadMore failure leaves the snapshot and initial status untouched")
    func loadMore_failure_isolatedToLoadMoreStatus() async {
        struct Boom: Error {}
        let core = makeCore(
            frontPage: { p in
                if p == 0 { return page([storyA, storyB], totalPages: 5) }
                throw Boom()
            }
        )

        await core.dispatch(.refresh)
        let before = await core.feedStories.map(\.id)

        await core.dispatch(.loadMore)

        #expect(await core.feedStories.map(\.id) == before)
        #expect(await core.feed.initialStatus.error == nil)
        #expect(await core.feed.loadMoreStatus.error != nil)
    }

    @Test("search paginates symmetrically with feed")
    func search_paginates() async {
        let core = makeCore(
            search: { _, p in
                if p == 0 { return page([storyA], totalPages: 2) }
                if p == 1 { return page([storyB], totalPages: 2) }
                return page([])
            }
        )

        await core.runSearchFetch(query: "x")
        #expect(await core.searchResults.map(\.id) == ["100"])
        #expect(await core.search.loadedHits?.hasMore == true)

        await core.runSearchLoadMore()
        #expect(await core.searchResults.map(\.id) == ["100", "101"])
        #expect(await core.search.loadedHits?.hasMore == false)
    }

    @Test("clearSearch cancels in-flight search load-more")
    func clearSearch_cancelsLoadMore() async {
        let core = makeCore(
            search: { _, p in
                if p == 0 { return page([storyA], totalPages: 5) }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                throw CancellationError()
            }
        )

        await core.runSearchFetch(query: "x")
        let loadMore = Task { [core] in
            await core.runSearchLoadMore()
        }
        await Task.megaYield()
        #expect(await core.search.loadMoreStatus.isLoading == true)

        await core.clearSearch()
        await loadMore.value

        #expect(await core.search.loadedHits == nil)
        #expect(await core.search.loadMoreStatus.isLoading == false)
        #expect(await core.search.loadMoreStatus.error == nil)
    }

    @Test("loadMore preserves loadedAt from the initial fetch")
    func loadMore_preservesLoadedAt() async {
        let core = makeCore(
            frontPage: { p in
                if p == 0 { return page([storyA], totalPages: 2) }
                return page([storyB], totalPages: 2)
            }
        )

        await core.dispatch(.refresh)
        let initialLoadedAt = await core.feed.loadedHits?.loadedAt

        try? await Task.sleep(for: .milliseconds(10))
        await core.dispatch(.loadMore)

        #expect(await core.feed.loadedHits?.loadedAt == initialLoadedAt)
    }
}
