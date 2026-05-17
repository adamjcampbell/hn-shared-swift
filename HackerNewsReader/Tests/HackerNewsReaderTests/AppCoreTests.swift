import Clocks
import Foundation
import Testing
import os
@testable import HackerNewsReader
import HackerNews

private let storyA = Story(
    id: "100", title: "Top story", author: "alice",
    score: 50, commentCount: 10,
    url: "https://example.com/a",
    createdAt: Date(timeIntervalSince1970: 1)
)
private let storyB = Story(
    id: "101", title: "Second story", author: "bob",
    score: 20, commentCount: 3,
    url: nil,
    createdAt: Date(timeIntervalSince1970: 2)
)
private let storyC = Story(
    id: "102", title: "Page-1 story", author: "carol",
    score: 9, commentCount: 1,
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

/// Test fixture for `TestCore` with optional `Client` mocks and an
/// injected clock. Defaults give an empty front page and an empty
/// search — override the relevant closure to express the test's intent.
private func makeCore(
    frontPage: @escaping @Sendable (Int) async throws -> Page = { _ in Page(stories: [], totalPages: 0) },
    search: @escaping @Sendable (String, Int) async throws -> Page = { _, _ in Page(stories: [], totalPages: 0) },
    clock: any Clock<Duration> = ContinuousClock(),
    now: @escaping @Sendable () -> Date = Date.init
) async -> TestCore {
    await TestCore(
        client: Client(frontPage: frontPage, search: search),
        clock: clock,
        now: now
    )
}

/// Sendable monotonic Date source for tests that need to assert
/// "this Date didn't change" without depending on `Date()` wall-clock
/// resolution. Each `next()` call returns a strictly later Date.
private final class MonotonicDates: Sendable {
    private let counter = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)
    func next() -> Date {
        counter.withLock { value in
            value += 1
            return Date(timeIntervalSince1970: value)
        }
    }
}

/// Convenience: a single-page response.
private func page(_ stories: [Story], totalPages: Int = 1) -> Page {
    Page(stories: stories, totalPages: totalPages)
}

private extension TestCore {
    /// Drive the listener-debounced search end-to-end: set the query,
    /// advance past the debounce, and let the commit land. Use when
    /// the test only cares about the post-commit state. Tests that
    /// assert mid-flight (during loading, during debounce) should
    /// inline the steps instead.
    func commitSearch(_ query: String, clock: TestClock<Duration>) async {
        await self.settle()
        await self.run { $0.state.searchQuery = query }
        await self.settle()
        await clock.advance(by: Self.searchDebounce)
        await self.settle()
    }
}

@Suite("AppCore")
struct AppCoreTests {

    @Test("refresh populates feed stories and timestamp")
    func refresh_populatesStoriesAndTimestamp() async {
        let core = await makeCore(frontPage: { _ in page([storyA, storyB]) })

        await core.run { core in
            #expect(core.state.feedStories.isEmpty)
            #expect(core.state.feedLoaded == nil)

            await core.appCore.sendEvent(.refresh)

            #expect(core.state.feedStories.count == 2)
            #expect(core.state.feedStories.first?.title == "Top story")
            #expect(core.state.feedLoaded?.loadedAt != nil)
            #expect(core.state.feedInitialStatus.error == nil)
        }
    }

    @Test("refresh records initialStatus.error on failure")
    func refresh_recordsErrorOnFailure() async {
        struct Boom: Error {}
        let core = await makeCore(
            frontPage: { _ in throw Boom() },
            search: { _, _ in throw Boom() }
        )

        await core.run { core in
            await core.appCore.sendEvent(.refresh)
            #expect(core.state.feedStories.isEmpty)
            #expect(core.state.feedInitialStatus.error != nil)
        }
    }

    @Test("toggleRead adds and removes")
    func toggleRead_addsAndRemoves() async {
        let core = await makeCore(frontPage: { _ in page([storyA]) })
        await core.run { core in
            await core.appCore.sendEvent(.refresh)
            #expect(core.state.feedStories.first?.isRead == false)

            await core.appCore.sendEvent(.toggleRead(id: storyA.id))
            #expect(core.state.feedStories.first?.isRead == true)
            #expect(core.state.readIds.contains(storyA.id))

            await core.appCore.sendEvent(.toggleRead(id: storyA.id))
            #expect(core.state.feedStories.first?.isRead == false)
            #expect(core.state.readIds.contains(storyA.id) == false)
        }
    }

    @Test("openStory marks read and emits presentURL command")
    func openStory_marksReadAndEmitsPresentURL() async {
        let core = await makeCore(frontPage: { _ in page([storyA, storyB]) })
        await core.run { await $0.appCore.sendEvent(.refresh) }

        var iterator = core.commands.makeAsyncIterator()
        await core.run { core in
            await core.appCore.sendEvent(.openStory(id: storyA.id))
            #expect(core.state.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)
        }
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("openStory on a story without a URL marks read but emits nothing")
    func openStory_withoutURL_marksReadOnly() async {
        let core = await makeCore(frontPage: { _ in page([storyA, storyB]) })
        await core.run { await $0.appCore.sendEvent(.refresh) }

        // Open storyB (no URL) then storyA (has URL). The first emission
        // we observe is storyA's — proving storyB emitted nothing.
        var iterator = core.commands.makeAsyncIterator()
        await core.run { core in
            await core.appCore.sendEvent(.openStory(id: storyB.id))
            await core.appCore.sendEvent(.openStory(id: storyA.id))
            #expect(core.state.feedStories.first(where: { $0.id == storyB.id })?.isRead == true)
        }
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("openStory with unknown id is a no-op")
    func openStory_unknownId_isNoop() async {
        let core = await makeCore(frontPage: { _ in page([storyA]) })
        var iterator = core.commands.makeAsyncIterator()
        await core.run { core in
            await core.appCore.sendEvent(.refresh)
            let readBefore = core.state.readIds
            await core.appCore.sendEvent(.openStory(id: "does-not-exist"))
            await core.appCore.sendEvent(.openStory(id: storyA.id))
            #expect(core.state.readIds == readBefore.union([storyA.id]))
        }
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("read state survives a refresh")
    func toggleRead_survivesRefresh() async {
        let core = await makeCore(frontPage: { _ in page([storyA, storyB]) })
        await core.run { core in
            // Toggle before any stories are loaded — readIds is the canonical
            // record; the projection has nothing to map onto yet.
            await core.appCore.sendEvent(.toggleRead(id: "100"))
            #expect(core.state.readIds.contains("100"))
            #expect(core.state.feedStories.isEmpty)

            await core.appCore.sendEvent(.refresh)
            let projected = core.state.feedStories.first(where: { $0.id == "100" })
            #expect(projected != nil)
            #expect(projected?.isRead == true)
        }
    }

    @Test("listener debounces and fires search with current query")
    func listener_debouncesAndFires() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let core = await makeCore(
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
    }

    @Test("initialStatus.isLoading activates on first keystroke, before debounce elapses")
    func isSearchLoading_activatesOnFirstKeystroke() async {
        let clock = TestClock()
        let core = await makeCore(search: { _, _ in page([storyA]) }, clock: clock)

        await core.settle()
        await core.run { core in
            #expect(core.state.searchInitialStatus.isLoading == false)
            core.state.searchQuery = "r"
        }
        await core.settle()

        // Spinner asserted synchronously on listener entry, before the debounce.
        await core.run { #expect($0.state.searchInitialStatus.isLoading == true) }

        await clock.advance(by: TestCore.searchDebounce)
        await core.settle()

        await core.run { #expect($0.state.searchInitialStatus.isLoading == false) }
    }

    @Test("URLError(.cancelled) from a cancelled feed fetch is treated as cancellation")
    func cancelledURLError_doesNotSurfaceAsFeedLoadError() async {
        // URLSession surfaces task cancellation as URLError.cancelled,
        // not Swift's CancellationError. Without the in-Task
        // normalisation, the sendEvent arm's generic `catch` would write
        // `feed.initialStatus.error = "cancelled"`.
        let core = await makeCore(
            frontPage: { _ in throw URLError(.cancelled) },
            search:    { _, _ in throw URLError(.cancelled) }
        )

        await core.run { core in
            await core.appCore.sendEvent(.refresh)
            #expect(core.state.feedInitialStatus.error == nil)
            #expect(core.state.feedLoaded == nil)
        }
    }

    @Test("search-to-search cancel-and-replace through URLError(.cancelled) doesn't surface")
    func searchCancelAndReplace_throughURLErrorCancelled_silent() async {
        // Without the URLError → CancellationError normalisation, the
        // prior sendEvent's catch arm would write
        // `search.initialStatus.error = "cancelled"` until the new
        // fetch settled.
        let clock = TestClock()
        let core = await makeCore(
            search: { query, _ in
                if query == "ru" {
                    // Park until cancelled; surface URLError(.cancelled) so
                    // we exercise AppCore's URLError → CancellationError
                    // normalisation.
                    do { try await clock.sleep(for: .seconds(Int.max)) }
                    catch { throw URLError(.cancelled) }
                }
                return page([storyA])
            },
            clock: clock
        )

        await core.settle()
        await core.run { $0.state.searchQuery = "ru" }
        await core.settle()
        await clock.advance(by: TestCore.searchDebounce)
        await core.settle()
        // "ru" is now parked in the cancel-loop inside the search mock.

        await core.run { $0.state.searchQuery = "rust" }
        await core.settle()
        await clock.advance(by: TestCore.searchDebounce)
        await core.settle()

        await core.run { core in
            #expect(core.state.searchInitialStatus.error == nil)
            #expect(core.state.searchQuery == "rust")
            #expect(core.state.searchResults.map(\.id) == ["100"])
        }
    }

    @Test("clearing the search query cancels the search, clears results, and does not refetch the feed")
    func clearingSearchQuery_cancelsAndClearsResults() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let core = await makeCore(
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

        let feedBefore = await core.run { core in
            await core.appCore.sendEvent(.refresh)
            return core.state.feedStories.map(\.id)
        }
        let frontPageBefore = await calls.frontPageCalls.count

        await core.commitSearch("rust", clock: clock)
        await core.run { core in
            #expect(core.state.searchResults.map(\.id) == ["100"])
            core.state.searchQuery = ""
        }
        await core.settle()

        await core.run { core in
            #expect(core.state.searchResults.isEmpty)
            #expect(core.state.searchInitialStatus.error == nil)
            #expect(core.state.searchInitialStatus.isLoading == false)
            #expect(core.state.searchLoaded == nil)
            #expect(core.state.feedStories.map(\.id) == feedBefore)
        }
        let frontPageAfter = await calls.frontPageCalls.count
        #expect(frontPageAfter == frontPageBefore)
        let searchCalls = await calls.searchCalls
        #expect(searchCalls.map(\.0) == ["rust"])
    }

    @Test("feed survives an active search")
    func feedSurvivesActiveSearch() async {
        let clock = TestClock()
        let core = await makeCore(
            frontPage: { _ in page([storyA, storyB]) },
            search: { _, _ in page([storyA]) },
            clock: clock
        )

        let feedSnapshot = await core.run { core in
            await core.appCore.sendEvent(.refresh)
            return core.state.feedStories.map(\.id)
        }
        #expect(feedSnapshot == ["100", "101"])

        await core.commitSearch("x", clock: clock)

        await core.run { core in
            #expect(core.state.searchResults.map(\.id) == ["100"])
            #expect(core.state.feedStories.map(\.id) == feedSnapshot)
        }
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
        let core = await makeCore(
            search: { query, p in
                await calls.recordSearch(query, page: p)
                return page([storyA])
            },
            clock: clock
        )

        // Let the listener spawned in `AppCore.init` reach
        // its `for await` suspension point before the first write.
        await core.settle()

        // Listener reads "rust" and schedules a search task that parks
        // in the debounce sleep.
        await core.run { $0.state.searchQuery = "rust" }
        await core.settle()

        // Backspace to empty. The non-blocking listener consumes this
        // immediately and calls `clearSearch()`, cancelling the parked
        // task before it reaches the network.
        await core.run { $0.state.searchQuery = "" }
        await core.settle()

        await clock.advance(by: TestCore.searchDebounce)
        await core.settle()

        await core.run { core in
            #expect(core.state.searchResults.isEmpty)
            #expect(core.state.searchInitialStatus.error == nil)
            #expect(core.state.searchInitialStatus.isLoading == false)
        }
        let recorded = await calls.searchCalls
        #expect(recorded.map(\.0) == [])
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
        let core = await makeCore(
            search: { query, p in
                await calls.recordSearch(query, page: p)
                return page([storyA])
            },
            clock: clock
        )

        // Let the listener spawned in `AppCore.init` reach
        // its `for await` suspension point before the first write.
        await core.settle()

        await core.run { $0.state.searchQuery = "r" }
        await core.settle()
        await core.run { $0.state.searchQuery = "ru" }
        await core.settle()
        await core.run { $0.state.searchQuery = "rust" }
        await core.settle()

        await clock.advance(by: TestCore.searchDebounce)
        await core.settle()

        let recorded = await calls.searchCalls
        #expect(recorded.map(\.0) == ["rust"])
        await core.run { #expect($0.state.searchResults.map(\.id) == ["100"]) }
    }

    @Test("a story present in both feed and search shares its read state across projections")
    func storyInBothFeedAndSearch_sharesReadState() async {
        let clock = TestClock()
        let core = await makeCore(
            frontPage: { _ in page([storyA, storyB]) },
            search: { _, _ in page([storyA]) },
            clock: clock
        )

        await core.run { core in
            await core.appCore.sendEvent(.refresh)
            await core.appCore.sendEvent(.toggleRead(id: storyA.id))
            #expect(core.state.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)
        }

        await core.commitSearch("x", clock: clock)

        await core.run { #expect($0.state.searchResults.first?.isRead == true) }
    }

    // MARK: Pagination

    @Test("loadMore appends page-1 ids to the snapshot and bumps the cursor")
    func loadMore_appendsAndBumpsCursor() async {
        let core = await makeCore(
            frontPage: { p in
                if p == 0 { return page([storyA, storyB], totalPages: 3) }
                if p == 1 { return page([storyC], totalPages: 3) }
                return page([])
            }
        )

        await core.run { core in
            await core.appCore.sendEvent(.refresh)
            #expect(core.state.feedLoaded?.page == 0)
            #expect(core.state.feedLoaded?.hasMore == true)
            #expect(core.state.feedStories.map(\.id) == ["100", "101"])

            await core.appCore.sendEvent(.loadMore)
            #expect(core.state.feedLoaded?.page == 1)
            #expect(core.state.feedLoaded?.hasMore == true)  // page 1 of 3, page 2 still remains
            #expect(core.state.feedStories.map(\.id) == ["100", "101", "102"])
        }
    }

    @Test("loadMore on the last page is a no-op")
    func loadMore_onLastPage_isNoop() async {
        let calls = CallRecorder()
        let core = await makeCore(
            frontPage: { p in
                await calls.recordFrontPage(page: p)
                return page([storyA], totalPages: 1)
            }
        )

        await core.run { core in
            await core.appCore.sendEvent(.refresh)
            #expect(core.state.feedLoaded?.hasMore == false)
            await core.appCore.sendEvent(.loadMore)
        }
        let pages = await calls.frontPageCalls
        #expect(pages == [0])  // only the initial fetch
    }

    @Test("loadMore before any initial fetch is a no-op")
    func loadMore_withoutInitial_isNoop() async {
        let calls = CallRecorder()
        let core = await makeCore(
            frontPage: { p in
                await calls.recordFrontPage(page: p)
                return page([storyA])
            }
        )

        await core.run { await $0.appCore.sendEvent(.loadMore) }
        let pages = await calls.frontPageCalls
        #expect(pages.isEmpty)
    }

    @Test("refresh during an in-flight loadMore cancels the loadMore")
    func refresh_duringLoadMore_cancelsLoadMore() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let core = await makeCore(
            frontPage: { p in
                await calls.recordFrontPage(page: p)
                if p == 1 {
                    // Park until the refresh cancels us.
                    try await clock.sleep(for: .seconds(Int.max))
                }
                return page([storyA], totalPages: 5)
            },
            clock: clock
        )

        await core.run { core in
            await core.appCore.sendEvent(.refresh)  // page 0 lands
            #expect(core.state.feedLoaded?.page == 0)
        }

        let loadMore = Task { [core] in
            await core.run { await $0.appCore.sendEvent(.loadMore) }
        }
        await core.settle()
        await core.run { #expect($0.state.feedLoadMoreStatus.isLoading == true) }

        // Refresh while page-1 is parked. Refresh's first action is
        // `tasks[.feedMore] = nil`, which cancels the parked task.
        await core.run { await $0.appCore.sendEvent(.refresh) }
        await loadMore.value

        // page resets to 0 after refresh; loadMore status cleared.
        await core.run { core in
            #expect(core.state.feedLoaded?.page == 0)
            #expect(core.state.feedLoadMoreStatus.isLoading == false)
            #expect(core.state.feedLoadMoreStatus.error == nil)
        }
    }

    @Test("loadMore failure leaves the snapshot and initial status untouched")
    func loadMore_failure_isolatedToLoadMoreStatus() async {
        struct Boom: Error {}
        let core = await makeCore(
            frontPage: { p in
                if p == 0 { return page([storyA, storyB], totalPages: 5) }
                throw Boom()
            }
        )

        await core.run { core in
            await core.appCore.sendEvent(.refresh)
            let before = core.state.feedStories.map(\.id)
            await core.appCore.sendEvent(.loadMore)
            #expect(core.state.feedStories.map(\.id) == before)
            #expect(core.state.feedInitialStatus.error == nil)
            #expect(core.state.feedLoadMoreStatus.error != nil)
        }
    }

    @Test("search paginates symmetrically with feed")
    func search_paginates() async {
        let clock = TestClock()
        let core = await makeCore(
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
            #expect(core.state.searchLoaded?.hasMore == true)

            await core.appCore.sendEvent(.loadMore)
            #expect(core.state.searchResults.map(\.id) == ["100", "101"])
            #expect(core.state.searchLoaded?.hasMore == false)
        }
    }

    @Test("clearing search cancels in-flight search load-more")
    func clearSearch_cancelsLoadMore() async {
        let clock = TestClock()
        let core = await makeCore(
            search: { _, p in
                if p == 0 { return page([storyA], totalPages: 5) }
                // Park until cancelled.
                try await clock.sleep(for: .seconds(Int.max))
                return page([])
            },
            clock: clock
        )

        await core.commitSearch("x", clock: clock)
        await core.run { #expect($0.state.searchLoaded?.hasMore == true) }

        let loadMore = Task { [core] in
            await core.run { await $0.appCore.sendEvent(.loadMore) }
        }
        await core.settle()
        await core.run { #expect($0.state.searchLoadMoreStatus.isLoading == true) }

        // Clear the search via the listener's empty-query path.
        await core.run { $0.state.searchQuery = "" }
        await loadMore.value
        await core.settle()

        await core.run { core in
            #expect(core.state.searchLoaded == nil)
            #expect(core.state.searchLoadMoreStatus.isLoading == false)
            #expect(core.state.searchLoadMoreStatus.error == nil)
        }
    }

    @Test("loadMore preserves loadedAt from the initial fetch")
    func loadMore_preservesLoadedAt() async {
        // Monotonic `now` so that *if* loadMore wrongly called
        // `receiveInitialPage`, its `loadedAt` would deterministically
        // differ from the refresh's — no Date()-resolution sleep needed.
        let dates = MonotonicDates()
        let core = await makeCore(
            frontPage: { p in
                if p == 0 { return page([storyA], totalPages: 2) }
                return page([storyB], totalPages: 2)
            },
            now: dates.next
        )

        await core.run { core in
            await core.appCore.sendEvent(.refresh)
            let initialLoadedAt = core.state.feedLoaded?.loadedAt
            await core.appCore.sendEvent(.loadMore)
            #expect(core.state.feedLoaded?.loadedAt == initialLoadedAt)
        }
    }
}
