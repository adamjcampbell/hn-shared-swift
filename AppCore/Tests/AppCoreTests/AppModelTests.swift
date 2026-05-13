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

/// Test fixture for `AppModel` with optional `HNClient` mocks and an
/// injected clock. Defaults give an empty front page and an empty
/// search — override the relevant closure to express the test's intent.
@MainActor
private func makeModel(
    frontPage: @escaping @Sendable (Int) async throws -> HNPage = { _ in HNPage(hits: [], totalPages: 0) },
    search: @escaping @Sendable (String, Int) async throws -> HNPage = { _, _ in HNPage(hits: [], totalPages: 0) },
    clock: any Clock<Duration> = ContinuousClock()
) -> AppModel {
    AppModel(
        client: HNClient(frontPage: frontPage, search: search),
        clock: clock
    )
}

/// Convenience: a single-page response.
private func page(_ hits: [HNHit], totalPages: Int = 1) -> HNPage {
    HNPage(hits: hits, totalPages: totalPages)
}

@Suite("AppModel")
@MainActor
struct AppModelTests {

    @Test("refresh populates feed stories and timestamp")
    func refresh_populatesStoriesAndTimestamp() async {
        let model = makeModel(frontPage: { _ in page([storyA, storyB]) })

        #expect(model.state.feedStories.isEmpty)
        #expect(model.state.feed.loadedHits == nil)

        await model.dispatch(.refresh)

        #expect(model.state.feedStories.count == 2)
        #expect(model.state.feedStories.first?.title == "Top story")
        #expect(model.state.feed.loadedHits?.loadedAt != nil)
        #expect(model.state.feed.initialStatus.error == nil)
    }

    @Test("refresh records initialStatus.error on failure")
    func refresh_recordsErrorOnFailure() async {
        struct Boom: Error {}
        let model = makeModel(
            frontPage: { _ in throw Boom() },
            search: { _, _ in throw Boom() }
        )

        await model.dispatch(.refresh)

        #expect(model.state.feedStories.isEmpty)
        #expect(model.state.feed.initialStatus.error != nil)
    }

    @Test("toggleRead adds and removes")
    func toggleRead_addsAndRemoves() async {
        let model = makeModel(frontPage: { _ in page([storyA]) })
        await model.dispatch(.refresh)
        #expect(model.state.feedStories.first?.isRead == false)

        await model.dispatch(.toggleRead(id: storyA.id))
        #expect(model.state.feedStories.first?.isRead == true)
        #expect(model.state.readIds.contains(storyA.id))

        await model.dispatch(.toggleRead(id: storyA.id))
        #expect(model.state.feedStories.first?.isRead == false)
        #expect(model.state.readIds.contains(storyA.id) == false)
    }

    @Test("openStory marks read and emits presentURL command")
    func openStory_marksReadAndEmitsPresentURL() async {
        let model = makeModel(frontPage: { _ in page([storyA, storyB]) })
        await model.dispatch(.refresh)

        var iterator = model.commands.makeAsyncIterator()
        await model.dispatch(.openStory(id: storyA.id))

        #expect(model.state.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("openStory on a story without a URL marks read but emits nothing")
    func openStory_withoutURL_marksReadOnly() async {
        let model = makeModel(frontPage: { _ in page([storyA, storyB]) })
        await model.dispatch(.refresh)

        // Open storyB (no URL) then storyA (has URL). The first emission
        // we observe is storyA's — proving storyB emitted nothing.
        var iterator = model.commands.makeAsyncIterator()
        await model.dispatch(.openStory(id: storyB.id))
        await model.dispatch(.openStory(id: storyA.id))

        #expect(model.state.feedStories.first(where: { $0.id == storyB.id })?.isRead == true)
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("openStory with unknown id is a no-op")
    func openStory_unknownId_isNoop() async {
        let model = makeModel(frontPage: { _ in page([storyA]) })
        await model.dispatch(.refresh)
        let readBefore = model.state.readIds

        var iterator = model.commands.makeAsyncIterator()
        await model.dispatch(.openStory(id: "does-not-exist"))
        await model.dispatch(.openStory(id: storyA.id))

        #expect(model.state.readIds == readBefore.union([storyA.id]))
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("read state survives a refresh")
    func toggleRead_survivesRefresh() async {
        let model = makeModel(frontPage: { _ in page([storyA, storyB]) })
        // Toggle before any stories are loaded — readIds is the canonical
        // record; the projection has nothing to map onto yet.
        await model.dispatch(.toggleRead(id: "100"))
        #expect(model.state.readIds.contains("100"))
        #expect(model.state.feedStories.isEmpty)

        await model.dispatch(.refresh)
        let projected = model.state.feedStories.first(where: { $0.id == "100" })
        #expect(projected != nil)
        #expect(projected?.isRead == true)
    }

    @Test("runSearchFetch debounces and fires search with current query")
    @MainActor
    func runSearchFetch_debouncesAndFires() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let model = makeModel(
            search: { query, p in
                await calls.recordSearch(query, page: p)
                return page([storyA])
            },
            clock: clock
        )

        model.state.searchQuery = "rust"
        let fetch = Task { @MainActor [model] in
            await model.handler.runSearchFetch(query: "rust", debounce: AppEventHandler.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppEventHandler.searchDebounce)
        await fetch.value

        #expect(model.state.searchQuery == "rust")
        #expect(model.state.searchResults.map(\.id) == ["100"])
        let recorded = await calls.searchCalls
        #expect(recorded.map(\.0) == ["rust"])
        #expect(recorded.map(\.1) == [0])
    }

    @Test("initialStatus.isLoading activates on first keystroke, before debounce elapses")
    @MainActor
    func isSearchLoading_activatesOnFirstKeystroke() async {
        let clock = TestClock()
        let model = makeModel(search: { _, _ in page([storyA]) }, clock: clock)

        #expect(model.state.search.initialStatus.isLoading == false)

        let fetch = Task { @MainActor [model] in
            await model.handler.runSearchFetch(query: "r", debounce: AppEventHandler.searchDebounce)
        }
        await Task.megaYield()

        // Spinner asserted synchronously on entry, before the debounce.
        #expect(model.state.search.initialStatus.isLoading == true)

        await clock.advance(by: AppEventHandler.searchDebounce)
        await fetch.value

        #expect(model.state.search.initialStatus.isLoading == false)
    }

    @Test("rapid runSearchFetch calls coalesce — only the latest fires")
    @MainActor
    func runSearchFetch_coalescesRapidKeystrokes() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let model = makeModel(
            search: { query, p in
                await calls.recordSearch(query, page: p)
                return page([storyA])
            },
            clock: clock
        )

        // Three back-to-back keystrokes; each runSearchFetch cancels the
        // prior in-flight searchTask, so only the latest query fires.
        model.state.searchQuery = "ru"
        let t1 = Task { @MainActor [model] in
            await model.handler.runSearchFetch(query: "ru", debounce: AppEventHandler.searchDebounce)
        }
        await Task.megaYield()
        model.state.searchQuery = "rus"
        let t2 = Task { @MainActor [model] in
            await model.handler.runSearchFetch(query: "rus", debounce: AppEventHandler.searchDebounce)
        }
        await Task.megaYield()
        model.state.searchQuery = "rust"
        let t3 = Task { @MainActor [model] in
            await model.handler.runSearchFetch(query: "rust", debounce: AppEventHandler.searchDebounce)
        }
        await Task.megaYield()

        await clock.advance(by: AppEventHandler.searchDebounce)
        await t1.value
        await t2.value
        await t3.value

        let recorded = await calls.searchCalls
        #expect(recorded.map(\.0) == ["rust"])
        #expect(model.state.searchQuery == "rust")
        #expect(model.state.searchResults.map(\.id) == ["100"])
    }

    @Test("refresh while a search is in flight re-runs the current search, not the feed")
    @MainActor
    func refresh_whileSearching_reRunsSearch() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let model = makeModel(
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

        model.state.searchQuery = "rust"
        let pending = Task { @MainActor [model] in
            await model.handler.runSearchFetch(query: "rust", debounce: AppEventHandler.searchDebounce)
        }
        await Task.megaYield()

        // .refresh with non-empty searchQuery re-runs the search; the
        // pending fetch is cancelled before it issues its own request.
        await model.dispatch(.refresh)
        await clock.advance(by: AppEventHandler.searchDebounce)
        await pending.value

        let frontPageCalls = await calls.frontPageCalls
        let searchCalls = await calls.searchCalls
        #expect(frontPageCalls.isEmpty)
        #expect(searchCalls.map(\.0) == ["rust"])
        #expect(model.state.searchResults.map(\.id) == ["100"])
    }

    @Test("dispatch resumes on caller's actor (SE-0461)")
    @MainActor
    func dispatch_runsOnCallersActor() async {
        let model = makeModel()
        await model.dispatch(.refresh)
        MainActor.assertIsolated()
    }

    @Test("URLError(.cancelled) from a cancelled feed fetch is treated as cancellation")
    @MainActor
    func cancelledURLError_doesNotSurfaceAsFeedLoadError() async {
        // URLSession surfaces task cancellation as URLError.cancelled,
        // not Swift's CancellationError. Without the in-Task
        // normalisation, the dispatch arm's generic `catch` would write
        // `feed.initialStatus.error = "cancelled"`.
        let model = makeModel(
            frontPage: { _ in throw URLError(.cancelled) },
            search:    { _, _ in throw URLError(.cancelled) }
        )

        await model.dispatch(.refresh)

        #expect(model.state.feed.initialStatus.error == nil)
        #expect(model.state.feed.loadedHits == nil)
    }

    @Test("search-to-search cancel-and-replace through URLError(.cancelled) doesn't surface")
    @MainActor
    func searchCancelAndReplace_throughURLErrorCancelled_silent() async {
        // Without the URLError → CancellationError normalisation, the
        // prior dispatch's catch arm would write
        // `search.initialStatus.error = "cancelled"` until the new
        // fetch settled.
        let clock = TestClock()
        let model = makeModel(
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

        model.state.searchQuery = "ru"
        let firstSearch = Task { @MainActor [model] in
            await model.handler.runSearchFetch(query: "ru", debounce: AppEventHandler.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppEventHandler.searchDebounce)
        await Task.megaYield()

        model.state.searchQuery = "rust"
        let secondSearch = Task { @MainActor [model] in
            await model.handler.runSearchFetch(query: "rust", debounce: AppEventHandler.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppEventHandler.searchDebounce)

        await firstSearch.value
        await secondSearch.value

        #expect(model.state.search.initialStatus.error == nil)
        #expect(model.state.searchQuery == "rust")
        #expect(model.state.searchResults.map(\.id) == ["100"])
    }

    @Test("clearing the search query cancels the search, clears results, and does not refetch the feed")
    @MainActor
    func clearingSearchQuery_cancelsAndClearsResults() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let model = makeModel(
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

        await model.dispatch(.refresh)
        let feedBefore = model.state.feedStories.map(\.id)
        let frontPageBefore = await calls.frontPageCalls.count

        model.state.searchQuery = "rust"
        let search = Task { @MainActor [model] in
            await model.handler.runSearchFetch(query: "rust", debounce: AppEventHandler.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppEventHandler.searchDebounce)
        await search.value
        #expect(model.state.searchResults.map(\.id) == ["100"])

        model.state.searchQuery = ""
        model.handler.clearSearch()

        #expect(model.state.searchResults.isEmpty)
        #expect(model.state.search.initialStatus.error == nil)
        #expect(model.state.search.initialStatus.isLoading == false)
        #expect(model.state.search.loadedHits == nil)
        #expect(model.state.feedStories.map(\.id) == feedBefore)
        let frontPageAfter = await calls.frontPageCalls.count
        #expect(frontPageAfter == frontPageBefore)
        let searchCalls = await calls.searchCalls
        #expect(searchCalls.map(\.0) == ["rust"])
    }

    @Test("feed survives an active search")
    @MainActor
    func feedSurvivesActiveSearch() async {
        let clock = TestClock()
        let model = makeModel(
            frontPage: { _ in page([storyA, storyB]) },
            search: { _, _ in page([storyA]) },
            clock: clock
        )

        await model.dispatch(.refresh)
        let feedSnapshot = model.state.feedStories.map(\.id)
        #expect(feedSnapshot == ["100", "101"])

        model.state.searchQuery = "x"
        let search = Task { @MainActor [model] in
            await model.handler.runSearchFetch(query: "x", debounce: AppEventHandler.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppEventHandler.searchDebounce)
        await search.value

        #expect(model.state.searchResults.map(\.id) == ["100"])
        #expect(model.state.feedStories.map(\.id) == feedSnapshot)
    }

    @Test("backspacing all the way to empty during an in-flight fetch still clears results")
    @MainActor
    func run_burstWriteDuringFetchClearsResults() async {
        // Regression: burst writes during an in-flight fetch must still
        // clear results when the final value is empty. The non-blocking
        // pipeline schedules "rust" (parked in the debounce sleep), then
        // immediately consumes the empty write, which calls
        // `clearSearch()` and cancels the parked task before its network
        // call fires — so zero recorded calls.
        let calls = CallRecorder()
        let clock = TestClock()
        let model = makeModel(
            search: { query, p in
                await calls.recordSearch(query, page: p)
                return page([storyA])
            },
            clock: clock
        )

        let pipeline = Task { @MainActor [model] in
            await model.run()
        }
        await Task.megaYield()

        // Pipeline reads "rust" and schedules a search task that parks
        // in the debounce sleep.
        model.state.searchQuery = "rust"
        await Task.megaYield()

        // Backspace to empty. The non-blocking pipeline consumes this
        // immediately and calls `clearSearch()`, cancelling the parked
        // task before it reaches the network.
        model.state.searchQuery = ""
        await Task.megaYield()

        await clock.advance(by: AppEventHandler.searchDebounce)
        await Task.megaYield()

        #expect(model.state.searchResults.isEmpty)
        #expect(model.state.search.initialStatus.error == nil)
        #expect(model.state.search.initialStatus.isLoading == false)
        let recorded = await calls.searchCalls
        #expect(recorded.map(\.0) == [])

        pipeline.cancel()
        _ = await pipeline.value
    }

    @Test("rapid keystrokes within the debounce window collapse to one search")
    @MainActor
    func run_rapidKeystrokes_onlyFinalQueryFires() async {
        // Regression: typing "rust" quickly used to produce two result
        // sets — the pre-fix watcher's `for await` blocked on the first
        // fetch's debounce, so "r" fired before the rest collapsed via
        // `.bufferingNewest(1)`. With the non-blocking pipeline, each
        // keystroke schedules a new task that cancels the prior in its
        // debounce sleep — only "rust" reaches the network.
        let calls = CallRecorder()
        let clock = TestClock()
        let model = makeModel(
            search: { query, p in
                await calls.recordSearch(query, page: p)
                return page([storyA])
            },
            clock: clock
        )

        let pipeline = Task { @MainActor [model] in
            await model.run()
        }
        await Task.megaYield()

        model.state.searchQuery = "r"
        await Task.megaYield()
        model.state.searchQuery = "ru"
        await Task.megaYield()
        model.state.searchQuery = "rust"
        await Task.megaYield()

        await clock.advance(by: AppEventHandler.searchDebounce)
        await Task.megaYield()

        let recorded = await calls.searchCalls
        #expect(recorded.map(\.0) == ["rust"])
        #expect(model.state.searchResults.map(\.id) == ["100"])

        pipeline.cancel()
        _ = await pipeline.value
    }

    @Test("a story present in both feed and search shares its read state across projections")
    @MainActor
    func storyInBothFeedAndSearch_sharesReadState() async {
        let clock = TestClock()
        let model = makeModel(
            frontPage: { _ in page([storyA, storyB]) },
            search: { _, _ in page([storyA]) },
            clock: clock
        )

        await model.dispatch(.refresh)
        await model.dispatch(.toggleRead(id: storyA.id))
        #expect(model.state.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)

        model.state.searchQuery = "x"
        let search = Task { @MainActor [model] in
            await model.handler.runSearchFetch(query: "x", debounce: AppEventHandler.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppEventHandler.searchDebounce)
        await search.value

        #expect(model.state.searchResults.first?.isRead == true)
    }

    // MARK: Pagination

    @Test("loadMore appends page-1 ids to the snapshot and bumps the cursor")
    @MainActor
    func loadMore_appendsAndBumpsCursor() async {
        let model = makeModel(
            frontPage: { p in
                if p == 0 { return page([storyA, storyB], totalPages: 3) }
                if p == 1 { return page([storyC], totalPages: 3) }
                return page([])
            }
        )

        await model.dispatch(.refresh)
        #expect(model.state.feed.loadedHits?.page == 0)
        #expect(model.state.feed.loadedHits?.hasMore == true)
        #expect(model.state.feedStories.map(\.id) == ["100", "101"])

        await model.dispatch(.loadMore)
        #expect(model.state.feed.loadedHits?.page == 1)
        #expect(model.state.feed.loadedHits?.hasMore == true)  // page 1 of 3, page 2 still remains
        #expect(model.state.feedStories.map(\.id) == ["100", "101", "102"])
    }

    @Test("loadMore on the last page is a no-op")
    @MainActor
    func loadMore_onLastPage_isNoop() async {
        let calls = CallRecorder()
        let model = makeModel(
            frontPage: { p in
                await calls.recordFrontPage(page: p)
                return page([storyA], totalPages: 1)
            }
        )

        await model.dispatch(.refresh)
        #expect(model.state.feed.loadedHits?.hasMore == false)

        await model.dispatch(.loadMore)
        let pages = await calls.frontPageCalls
        #expect(pages == [0])  // only the initial fetch
    }

    @Test("loadMore before any initial fetch is a no-op")
    @MainActor
    func loadMore_withoutInitial_isNoop() async {
        let calls = CallRecorder()
        let model = makeModel(
            frontPage: { p in
                await calls.recordFrontPage(page: p)
                return page([storyA])
            }
        )

        await model.dispatch(.loadMore)
        let pages = await calls.frontPageCalls
        #expect(pages.isEmpty)
    }

    @Test("refresh during an in-flight loadMore cancels the loadMore")
    @MainActor
    func refresh_duringLoadMore_cancelsLoadMore() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let model = makeModel(
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

        await model.dispatch(.refresh)  // page 0 lands
        #expect(model.state.feed.loadedHits?.page == 0)

        let loadMore = Task { @MainActor [model] in
            await model.handler.runFeedLoadMore()
        }
        await Task.megaYield()
        #expect(model.state.feed.loadMoreStatus.isLoading == true)

        // Refresh while page-1 is parked. Refresh's first action is
        // `tasks[.feedMore] = nil`, which cancels the parked task.
        await model.dispatch(.refresh)
        await loadMore.value

        // page resets to 0 after refresh; loadMore status cleared.
        #expect(model.state.feed.loadedHits?.page == 0)
        #expect(model.state.feed.loadMoreStatus.isLoading == false)
        #expect(model.state.feed.loadMoreStatus.error == nil)
    }

    @Test("loadMore failure leaves the snapshot and initial status untouched")
    @MainActor
    func loadMore_failure_isolatedToLoadMoreStatus() async {
        struct Boom: Error {}
        let model = makeModel(
            frontPage: { p in
                if p == 0 { return page([storyA, storyB], totalPages: 5) }
                throw Boom()
            }
        )

        await model.dispatch(.refresh)
        let before = model.state.feedStories.map(\.id)

        await model.dispatch(.loadMore)

        #expect(model.state.feedStories.map(\.id) == before)
        #expect(model.state.feed.initialStatus.error == nil)
        #expect(model.state.feed.loadMoreStatus.error != nil)
    }

    @Test("search paginates symmetrically with feed")
    @MainActor
    func search_paginates() async {
        let model = makeModel(
            search: { _, p in
                if p == 0 { return page([storyA], totalPages: 2) }
                if p == 1 { return page([storyB], totalPages: 2) }
                return page([])
            }
        )

        await model.handler.runSearchFetch(query: "x")
        #expect(model.state.searchResults.map(\.id) == ["100"])
        #expect(model.state.search.loadedHits?.hasMore == true)

        await model.handler.runSearchLoadMore()
        #expect(model.state.searchResults.map(\.id) == ["100", "101"])
        #expect(model.state.search.loadedHits?.hasMore == false)
    }

    @Test("clearSearch cancels in-flight search load-more")
    @MainActor
    func clearSearch_cancelsLoadMore() async {
        let model = makeModel(
            search: { _, p in
                if p == 0 { return page([storyA], totalPages: 5) }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                throw CancellationError()
            }
        )

        await model.handler.runSearchFetch(query: "x")
        let loadMore = Task { @MainActor [model] in
            await model.handler.runSearchLoadMore()
        }
        await Task.megaYield()
        #expect(model.state.search.loadMoreStatus.isLoading == true)

        model.handler.clearSearch()
        await loadMore.value

        #expect(model.state.search.loadedHits == nil)
        #expect(model.state.search.loadMoreStatus.isLoading == false)
        #expect(model.state.search.loadMoreStatus.error == nil)
    }

    @Test("loadMore preserves loadedAt from the initial fetch")
    @MainActor
    func loadMore_preservesLoadedAt() async {
        let model = makeModel(
            frontPage: { p in
                if p == 0 { return page([storyA], totalPages: 2) }
                return page([storyB], totalPages: 2)
            }
        )

        await model.dispatch(.refresh)
        let initialLoadedAt = model.state.feed.loadedHits?.loadedAt

        try? await Task.sleep(for: .milliseconds(10))
        await model.dispatch(.loadMore)

        #expect(model.state.feed.loadedHits?.loadedAt == initialLoadedAt)
    }
}
