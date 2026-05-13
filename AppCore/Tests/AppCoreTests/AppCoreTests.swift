import Clocks
import ConcurrencyExtras
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

private extension TestCore {
    /// Drive the listener-debounced search end-to-end: set the query,
    /// advance past the debounce, and let the commit land. Use when
    /// the test only cares about the post-commit state. Tests that
    /// assert mid-flight (during loading, during debounce) should
    /// inline the steps instead.
    func commitSearch(_ query: String, clock: TestClock<Duration>) async {
        await Task.megaYield()
        await self.run { $0.state.searchQuery = query }
        await Task.megaYield()
        await clock.advance(by: Self.searchDebounce)
        await Task.megaYield()
    }
}

@Suite("AppCore")
struct AppCoreTests {

    @Test("refresh populates feed stories and timestamp")
    func refresh_populatesStoriesAndTimestamp() async {
        let core = makeCore(frontPage: { _ in page([storyA, storyB]) })

        await core.run { core in
            #expect(core.state.feedStories.isEmpty)
            #expect(core.state.feed.loadedHits == nil)
        }

        await core.run { await $0.appCore.dispatch(.refresh) }

        await core.run { core in
            #expect(core.state.feedStories.count == 2)
            #expect(core.state.feedStories.first?.title == "Top story")
            #expect(core.state.feed.loadedHits?.loadedAt != nil)
            #expect(core.state.feed.initialStatus.error == nil)
        }
    }

    @Test("refresh records initialStatus.error on failure")
    func refresh_recordsErrorOnFailure() async {
        struct Boom: Error {}
        let core = makeCore(
            frontPage: { _ in throw Boom() },
            search: { _, _ in throw Boom() }
        )

        await core.run { await $0.appCore.dispatch(.refresh) }

        await core.run { core in
            #expect(core.state.feedStories.isEmpty)
            #expect(core.state.feed.initialStatus.error != nil)
        }
    }

    @Test("toggleRead adds and removes")
    func toggleRead_addsAndRemoves() async {
        let core = makeCore(frontPage: { _ in page([storyA]) })
        await core.run { await $0.appCore.dispatch(.refresh) }
        await core.run { #expect($0.state.feedStories.first?.isRead == false) }

        await core.run { await $0.appCore.dispatch(.toggleRead(id: storyA.id)) }
        await core.run { core in
            #expect(core.state.feedStories.first?.isRead == true)
            #expect(core.state.readIds.contains(storyA.id))
        }

        await core.run { await $0.appCore.dispatch(.toggleRead(id: storyA.id)) }
        await core.run { core in
            #expect(core.state.feedStories.first?.isRead == false)
            #expect(core.state.readIds.contains(storyA.id) == false)
        }
    }

    @Test("openStory marks read and emits presentURL command")
    func openStory_marksReadAndEmitsPresentURL() async {
        let core = makeCore(frontPage: { _ in page([storyA, storyB]) })
        await core.run { await $0.appCore.dispatch(.refresh) }

        var iterator = core.commands.makeAsyncIterator()
        await core.run { await $0.appCore.dispatch(.openStory(id: storyA.id)) }

        await core.run { #expect($0.state.feedStories.first(where: { $0.id == storyA.id })?.isRead == true) }
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("openStory on a story without a URL marks read but emits nothing")
    func openStory_withoutURL_marksReadOnly() async {
        let core = makeCore(frontPage: { _ in page([storyA, storyB]) })
        await core.run { await $0.appCore.dispatch(.refresh) }

        // Open storyB (no URL) then storyA (has URL). The first emission
        // we observe is storyA's — proving storyB emitted nothing.
        var iterator = core.commands.makeAsyncIterator()
        await core.run { await $0.appCore.dispatch(.openStory(id: storyB.id)) }
        await core.run { await $0.appCore.dispatch(.openStory(id: storyA.id)) }

        await core.run { #expect($0.state.feedStories.first(where: { $0.id == storyB.id })?.isRead == true) }
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("openStory with unknown id is a no-op")
    func openStory_unknownId_isNoop() async {
        let core = makeCore(frontPage: { _ in page([storyA]) })
        await core.run { await $0.appCore.dispatch(.refresh) }
        let readBefore = await core.run { $0.state.readIds }

        var iterator = core.commands.makeAsyncIterator()
        await core.run { await $0.appCore.dispatch(.openStory(id: "does-not-exist")) }
        await core.run { await $0.appCore.dispatch(.openStory(id: storyA.id)) }

        await core.run { #expect($0.state.readIds == readBefore.union([storyA.id])) }
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("read state survives a refresh")
    func toggleRead_survivesRefresh() async {
        let core = makeCore(frontPage: { _ in page([storyA, storyB]) })
        // Toggle before any stories are loaded — readIds is the canonical
        // record; the projection has nothing to map onto yet.
        await core.run { await $0.appCore.dispatch(.toggleRead(id: "100")) }
        await core.run { core in
            #expect(core.state.readIds.contains("100"))
            #expect(core.state.feedStories.isEmpty)
        }

        await core.run { await $0.appCore.dispatch(.refresh) }
        await core.run { core in
            let projected = core.state.feedStories.first(where: { $0.id == "100" })
            #expect(projected != nil)
            #expect(projected?.isRead == true)
        }
    }

    @Test("listener debounces and fires search with current query")
    func listener_debouncesAndFires() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let core = makeCore(
            search: { query, p in
                await calls.recordSearch(query, page: p)
                return page([storyA])
            },
            clock: clock
        )

        await core.commitSearch("rust", clock: clock)

        await core.run { core in
            #expect(core.state.searchQuery == "rust")
            #expect(core.state.searchResults.map(\.id) == ["100"])
        }
        let recorded = await calls.searchCalls
        #expect(recorded.map(\.0) == ["rust"])
        #expect(recorded.map(\.1) == [0])

        await core.run { $0.appCore.shutdown() }
    }

    @Test("initialStatus.isLoading activates on first keystroke, before debounce elapses")
    func isSearchLoading_activatesOnFirstKeystroke() async {
        let clock = TestClock()
        let core = makeCore(search: { _, _ in page([storyA]) }, clock: clock)

        await core.run { #expect($0.state.search.initialStatus.isLoading == false) }

        await Task.megaYield()
        await core.run { $0.state.searchQuery = "r" }
        await Task.megaYield()

        // Spinner asserted synchronously on listener entry, before the debounce.
        await core.run { #expect($0.state.search.initialStatus.isLoading == true) }

        await clock.advance(by: TestCore.searchDebounce)
        await Task.megaYield()

        await core.run { #expect($0.state.search.initialStatus.isLoading == false) }

        await core.run { $0.appCore.shutdown() }
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

        await Task.megaYield()
        await core.run { $0.state.searchQuery = "rust" }
        await Task.megaYield()
        // Listener has spawned a debounced fetch parked in clock.sleep.

        // .refresh with non-empty searchQuery re-runs the search; the
        // pending listener fetch is cancelled before its sleep elapses.
        await core.run { await $0.appCore.dispatch(.refresh) }
        await clock.advance(by: TestCore.searchDebounce)
        await Task.megaYield()

        let frontPageCalls = await calls.frontPageCalls
        let searchCalls = await calls.searchCalls
        #expect(frontPageCalls.isEmpty)
        #expect(searchCalls.map(\.0) == ["rust"])
        await core.run { #expect($0.state.searchResults.map(\.id) == ["100"]) }

        await core.run { $0.appCore.shutdown() }
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

        await core.run { await $0.appCore.dispatch(.refresh) }

        await core.run { core in
            #expect(core.state.feed.initialStatus.error == nil)
            #expect(core.state.feed.loadedHits == nil)
        }
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

        await Task.megaYield()
        await core.run { $0.state.searchQuery = "ru" }
        await Task.megaYield()
        await clock.advance(by: TestCore.searchDebounce)
        await Task.megaYield()
        // "ru" is now parked in the cancel-loop inside the search mock.

        await core.run { $0.state.searchQuery = "rust" }
        await Task.megaYield()
        await clock.advance(by: TestCore.searchDebounce)
        await Task.megaYield()

        await core.run { core in
            #expect(core.state.search.initialStatus.error == nil)
            #expect(core.state.searchQuery == "rust")
            #expect(core.state.searchResults.map(\.id) == ["100"])
        }

        await core.run { $0.appCore.shutdown() }
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

        await core.run { await $0.appCore.dispatch(.refresh) }
        let feedBefore = await core.run { $0.state.feedStories.map(\.id) }
        let frontPageBefore = await calls.frontPageCalls.count

        await core.commitSearch("rust", clock: clock)
        await core.run { #expect($0.state.searchResults.map(\.id) == ["100"]) }

        await core.run { $0.state.searchQuery = "" }
        await Task.megaYield()

        await core.run { core in
            #expect(core.state.searchResults.isEmpty)
            #expect(core.state.search.initialStatus.error == nil)
            #expect(core.state.search.initialStatus.isLoading == false)
            #expect(core.state.search.loadedHits == nil)
            #expect(core.state.feedStories.map(\.id) == feedBefore)
        }
        let frontPageAfter = await calls.frontPageCalls.count
        #expect(frontPageAfter == frontPageBefore)
        let searchCalls = await calls.searchCalls
        #expect(searchCalls.map(\.0) == ["rust"])

        await core.run { $0.appCore.shutdown() }
    }

    @Test("feed survives an active search")
    func feedSurvivesActiveSearch() async {
        let clock = TestClock()
        let core = makeCore(
            frontPage: { _ in page([storyA, storyB]) },
            search: { _, _ in page([storyA]) },
            clock: clock
        )

        await core.run { await $0.appCore.dispatch(.refresh) }
        let feedSnapshot = await core.run { $0.state.feedStories.map(\.id) }
        #expect(feedSnapshot == ["100", "101"])

        await core.commitSearch("x", clock: clock)

        await core.run { core in
            #expect(core.state.searchResults.map(\.id) == ["100"])
            #expect(core.state.feedStories.map(\.id) == feedSnapshot)
        }

        await core.run { $0.appCore.shutdown() }
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

        // Let the listener spawned in `AppCore.init` reach
        // its `for await` suspension point before the first write.
        await Task.megaYield()

        // Listener reads "rust" and schedules a search task that parks
        // in the debounce sleep.
        await core.run { $0.state.searchQuery = "rust" }
        await Task.megaYield()

        // Backspace to empty. The non-blocking listener consumes this
        // immediately and calls `clearSearch()`, cancelling the parked
        // task before it reaches the network.
        await core.run { $0.state.searchQuery = "" }
        await Task.megaYield()

        await clock.advance(by: TestCore.searchDebounce)
        await Task.megaYield()

        await core.run { core in
            #expect(core.state.searchResults.isEmpty)
            #expect(core.state.search.initialStatus.error == nil)
            #expect(core.state.search.initialStatus.isLoading == false)
        }
        let recorded = await calls.searchCalls
        #expect(recorded.map(\.0) == [])

        await core.run { $0.appCore.shutdown() }
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

        // Let the listener spawned in `AppCore.init` reach
        // its `for await` suspension point before the first write.
        await Task.megaYield()

        await core.run { $0.state.searchQuery = "r" }
        await Task.megaYield()
        await core.run { $0.state.searchQuery = "ru" }
        await Task.megaYield()
        await core.run { $0.state.searchQuery = "rust" }
        await Task.megaYield()

        await clock.advance(by: TestCore.searchDebounce)
        await Task.megaYield()

        let recorded = await calls.searchCalls
        #expect(recorded.map(\.0) == ["rust"])
        await core.run { #expect($0.state.searchResults.map(\.id) == ["100"]) }

        await core.run { $0.appCore.shutdown() }
    }

    @Test("a story present in both feed and search shares its read state across projections")
    func storyInBothFeedAndSearch_sharesReadState() async {
        let clock = TestClock()
        let core = makeCore(
            frontPage: { _ in page([storyA, storyB]) },
            search: { _, _ in page([storyA]) },
            clock: clock
        )

        await core.run { await $0.appCore.dispatch(.refresh) }
        await core.run { await $0.appCore.dispatch(.toggleRead(id: storyA.id)) }
        await core.run { #expect($0.state.feedStories.first(where: { $0.id == storyA.id })?.isRead == true) }

        await core.commitSearch("x", clock: clock)

        await core.run { #expect($0.state.searchResults.first?.isRead == true) }

        await core.run { $0.appCore.shutdown() }
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

        await core.run { await $0.appCore.dispatch(.refresh) }
        await core.run { core in
            #expect(core.state.feed.loadedHits?.page == 0)
            #expect(core.state.feed.loadedHits?.hasMore == true)
            #expect(core.state.feedStories.map(\.id) == ["100", "101"])
        }

        await core.run { await $0.appCore.dispatch(.loadMore) }
        await core.run { core in
            #expect(core.state.feed.loadedHits?.page == 1)
            #expect(core.state.feed.loadedHits?.hasMore == true)  // page 1 of 3, page 2 still remains
            #expect(core.state.feedStories.map(\.id) == ["100", "101", "102"])
        }
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

        await core.run { await $0.appCore.dispatch(.refresh) }
        await core.run { #expect($0.state.feed.loadedHits?.hasMore == false) }

        await core.run { await $0.appCore.dispatch(.loadMore) }
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

        await core.run { await $0.appCore.dispatch(.loadMore) }
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

        await core.run { await $0.appCore.dispatch(.refresh) }  // page 0 lands
        await core.run { #expect($0.state.feed.loadedHits?.page == 0) }

        let loadMore = Task { [core] in
            await core.run { await $0.appCore.dispatch(.loadMore) }
        }
        await Task.megaYield()
        await core.run { #expect($0.state.feed.loadMoreStatus.isLoading == true) }

        // Refresh while page-1 is parked. Refresh's first action is
        // `tasks[.feedMore] = nil`, which cancels the parked task.
        await core.run { await $0.appCore.dispatch(.refresh) }
        await loadMore.value

        // page resets to 0 after refresh; loadMore status cleared.
        await core.run { core in
            #expect(core.state.feed.loadedHits?.page == 0)
            #expect(core.state.feed.loadMoreStatus.isLoading == false)
            #expect(core.state.feed.loadMoreStatus.error == nil)
        }
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

        await core.run { await $0.appCore.dispatch(.refresh) }
        let before = await core.run { $0.state.feedStories.map(\.id) }

        await core.run { await $0.appCore.dispatch(.loadMore) }

        await core.run { core in
            #expect(core.state.feedStories.map(\.id) == before)
            #expect(core.state.feed.initialStatus.error == nil)
            #expect(core.state.feed.loadMoreStatus.error != nil)
        }
    }

    @Test("search paginates symmetrically with feed")
    func search_paginates() async {
        let clock = TestClock()
        let core = makeCore(
            search: { _, p in
                if p == 0 { return page([storyA], totalPages: 2) }
                if p == 1 { return page([storyB], totalPages: 2) }
                return page([])
            },
            clock: clock
        )

        await core.commitSearch("x", clock: clock)
        await core.run { core in
            #expect(core.state.searchResults.map(\.id) == ["100"])
            #expect(core.state.search.loadedHits?.hasMore == true)
        }

        await core.run { await $0.appCore.dispatch(.loadMore) }
        await core.run { core in
            #expect(core.state.searchResults.map(\.id) == ["100", "101"])
            #expect(core.state.search.loadedHits?.hasMore == false)
        }

        await core.run { $0.appCore.shutdown() }
    }

    @Test("clearing search cancels in-flight search load-more")
    func clearSearch_cancelsLoadMore() async {
        let clock = TestClock()
        let core = makeCore(
            search: { _, p in
                if p == 0 { return page([storyA], totalPages: 5) }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                throw CancellationError()
            },
            clock: clock
        )

        await core.commitSearch("x", clock: clock)
        await core.run { #expect($0.state.search.loadedHits?.hasMore == true) }

        let loadMore = Task { [core] in
            await core.run { await $0.appCore.dispatch(.loadMore) }
        }
        await Task.megaYield()
        await core.run { #expect($0.state.search.loadMoreStatus.isLoading == true) }

        // Clear the search via the listener's empty-query path.
        await core.run { $0.state.searchQuery = "" }
        await loadMore.value
        await Task.megaYield()

        await core.run { core in
            #expect(core.state.search.loadedHits == nil)
            #expect(core.state.search.loadMoreStatus.isLoading == false)
            #expect(core.state.search.loadMoreStatus.error == nil)
        }

        await core.run { $0.appCore.shutdown() }
    }

    @Test("loadMore preserves loadedAt from the initial fetch")
    func loadMore_preservesLoadedAt() async {
        let core = makeCore(
            frontPage: { p in
                if p == 0 { return page([storyA], totalPages: 2) }
                return page([storyB], totalPages: 2)
            }
        )

        await core.run { await $0.appCore.dispatch(.refresh) }
        let initialLoadedAt = await core.run { $0.state.feed.loadedHits?.loadedAt }

        try? await Task.sleep(for: .milliseconds(10))
        await core.run { await $0.appCore.dispatch(.loadMore) }

        await core.run { #expect($0.state.feed.loadedHits?.loadedAt == initialLoadedAt) }
    }
}
