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

/// Records the queries (and pages) the mock client was called with.
private struct CallRecorder {
    private struct State { var frontPageCalls: [Int] = []; var searchCalls: [(String, Int)] = [] }
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    var frontPageCalls: [Int] { lock.withLock { $0.frontPageCalls } }
    var searchCalls: [(String, Int)] { lock.withLock { $0.searchCalls } }

    func recordFrontPage(page: Int) { lock.withLock { $0.frontPageCalls.append(page) } }
    func recordSearch(_ query: String, page: Int) { lock.withLock { $0.searchCalls.append((query, page)) } }
}

/// Convenience: a single-page response.
private func page(_ stories: [Story], totalPages: Int = 1) -> Page {
    Page(stories: stories, totalPages: totalPages)
}

/// Drives the listener-debounced search to commit. Inline the steps
/// instead when asserting mid-flight. Pass the same `TestClock` the
/// fixture was given so the debounce sleep can be advanced.
///
/// `waitUntil` covers the two observable transitions — the listener
/// picking up the query (`isLoading`) and the commit (`searchLoaded`).
/// The lone `runPending` is irreducible: it drains the fetch `Task` to
/// its `clock.sleep` so `advance` lands on a parked sleeper, and "the
/// task is now sleeping" has no observable signal.
private func commitSearch(
    _ query: String,
    core: Core,
    clock: TestClock<Duration>,
    isolation: isolated TestActor
) async {
    core.model.searchQuery = query
    await waitUntil { core.model.searchInitialStatus.isLoading }
    await isolation.runPending()
    await clock.advance(by: Core.searchDebounce)
    await waitUntil { core.model.searchLoaded != nil }
}

@Suite("Core")
struct CoreTests {

    @Test("refresh populates feed stories and timestamp")
    func refresh_populatesStoriesAndTimestamp() async throws {
        try await withCore(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { _, core in
            let model = core.model
            #expect(model.feedStories.isEmpty)
            #expect(model.feedLoaded == nil)

            await core.sendMessage(.refresh)

            #expect(model.feedStories.count == 2)
            #expect(model.feedStories.first?.title == "Top story")
            #expect(model.feedLoaded?.loadedAt != nil)
            #expect(model.feedInitialStatus.error == nil)
        }
    }

    @Test("refresh records initialStatus.error on failure")
    func refresh_recordsErrorOnFailure() async throws {
        struct Boom: Error {}
        try await withCore(
            client: .mock(
                frontPage: { _ in throw Boom() },
                search: { _, _ in throw Boom() }
            )
        ) { _, core in
            let model = core.model
            await core.sendMessage(.refresh)
            #expect(model.feedStories.isEmpty)
            #expect(model.feedInitialStatus.error != nil)
        }
    }

    @Test("toggleRead adds and removes")
    func toggleRead_addsAndRemoves() async throws {
        try await withCore(
            client: .mock(frontPage: { _ in page([storyA]) })
        ) { _, core in
            let model = core.model
            await core.sendMessage(.refresh)
            #expect(model.feedStories.first?.isRead == false)

            await core.sendMessage(.toggleRead(id: storyA.id))
            #expect(model.feedStories.first?.isRead == true)
            #expect(model.readIds.contains(storyA.id))

            await core.sendMessage(.toggleRead(id: storyA.id))
            #expect(model.feedStories.first?.isRead == false)
            #expect(model.readIds.contains(storyA.id) == false)
        }
    }

    @Test("openStory marks read and emits presentURL command")
    func openStory_marksReadAndEmitsPresentURL() async throws {
        try await withCore(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { _, core in
            await core.sendMessage(.refresh)

            var iterator = core.commands.makeAsyncIterator()
            let model = core.model
            await core.sendMessage(.openStory(id: storyA.id))
            #expect(model.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)

            let command = await iterator.next()
            #expect(command == .presentURL(value: storyA.url!))
        }
    }

    @Test("openStory on a story without a URL marks read but emits nothing")
    func openStory_withoutURL_marksReadOnly() async throws {
        try await withCore(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { _, core in
            await core.sendMessage(.refresh)

            // First emission we observe is storyA's — proves storyB emitted nothing.
            var iterator = core.commands.makeAsyncIterator()
            let model = core.model
            await core.sendMessage(.openStory(id: storyB.id))
            await core.sendMessage(.openStory(id: storyA.id))
            #expect(model.feedStories.first(where: { $0.id == storyB.id })?.isRead == true)

            let command = await iterator.next()
            #expect(command == .presentURL(value: storyA.url!))
        }
    }

    @Test("openStory with unknown id is a no-op")
    func openStory_unknownId_isNoop() async throws {
        try await withCore(
            client: .mock(frontPage: { _ in page([storyA]) })
        ) { _, core in
            var iterator = core.commands.makeAsyncIterator()
            let model = core.model
            await core.sendMessage(.refresh)
            let readBefore = model.readIds
            await core.sendMessage(.openStory(id: "does-not-exist"))
            await core.sendMessage(.openStory(id: storyA.id))
            #expect(model.readIds == readBefore.union([storyA.id]))

            let command = await iterator.next()
            #expect(command == .presentURL(value: storyA.url!))
        }
    }

    @Test("read state survives a refresh")
    func toggleRead_survivesRefresh() async throws {
        try await withCore(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { _, core in
            let model = core.model
            await core.sendMessage(.toggleRead(id: "100"))
            #expect(model.readIds.contains("100"))
            #expect(model.feedStories.isEmpty)

            await core.sendMessage(.refresh)
            let projected = model.feedStories.first(where: { $0.id == "100" })
            #expect(projected != nil)
            #expect(projected?.isRead == true)
        }
    }

    @Test("listener debounces and fires search with current query")
    func listener_debouncesAndFires() async throws {
        let calls = CallRecorder()
        let clock = TestClock<Duration>()
        try await withCore(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            clock: clock
        ) { actor, core in
            await commitSearch("rust", core: core, clock: clock, isolation: actor)

            let model = core.model
            #expect(model.searchQuery == "rust")
            #expect(model.searchResults.map(\.id) == ["100"])

            let recorded = calls.searchCalls
            #expect(recorded.map(\.0) == ["rust"])
            #expect(recorded.map(\.1) == [0])
        }
    }

    @Test("initialStatus.isLoading activates on first keystroke, before debounce elapses")
    func isSearchLoading_activatesOnFirstKeystroke() async throws {
        let clock = TestClock<Duration>()
        try await withCore(
            client: .mock(search: { _, _ in page([storyA]) }),
            clock: clock
        ) { actor, core in
            let model = core.model
            #expect(model.searchInitialStatus.isLoading == false)
            model.searchQuery = "r"
            await waitUntil { model.searchInitialStatus.isLoading }

            #expect(model.searchInitialStatus.isLoading == true)

            await actor.runPending()
            await clock.advance(by: Core.searchDebounce)
            await waitUntil { !model.searchInitialStatus.isLoading }

            #expect(model.searchInitialStatus.isLoading == false)
        }
    }

    @Test("URLError(.cancelled) from a cancelled feed fetch is treated as cancellation")
    func cancelledURLError_doesNotSurfaceAsFeedLoadError() async throws {
        // URLSession surfaces task cancellation as URLError.cancelled, not CancellationError.
        try await withCore(
            client: .mock(
                frontPage: { _ in throw URLError(.cancelled) },
                search:    { _, _ in throw URLError(.cancelled) }
            )
        ) { _, core in
            let model = core.model
            await core.sendMessage(.refresh)
            #expect(model.feedInitialStatus.error == nil)
            #expect(model.feedLoaded == nil)
        }
    }

    @Test("search-to-search cancel-and-replace through URLError(.cancelled) doesn't surface")
    func searchCancelAndReplace_throughURLErrorCancelled_silent() async throws {
        let clock = TestClock<Duration>()
        try await withCore(
            client: .mock(
                search: { query, _ in
                    if query == "ru" {
                        do { try await clock.sleep(for: .seconds(Int.max)) }
                        catch { throw URLError(.cancelled) }
                    }
                    return page([storyA])
                }
            ),
            clock: clock
        ) { actor, core in
            await settle(actor)
            core.model.searchQuery = "ru"
            await settle(actor)
            await clock.advance(by: Core.searchDebounce)
            await settle(actor)

            core.model.searchQuery = "rust"
            await settle(actor)
            await clock.advance(by: Core.searchDebounce)
            await settle(actor)

            let model = core.model
            #expect(model.searchInitialStatus.error == nil)
            #expect(model.searchQuery == "rust")
            #expect(model.searchResults.map(\.id) == ["100"])
        }
    }

    @Test("clearing the search query cancels the search, clears results, and does not refetch the feed")
    func clearingSearchQuery_cancelsAndClearsResults() async throws {
        let calls = CallRecorder()
        let clock = TestClock<Duration>()
        try await withCore(
            client: .mock(
                frontPage: { p in
                    calls.recordFrontPage(page: p)
                    return page([storyA, storyB])
                },
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            clock: clock
        ) { actor, core in
            await core.sendMessage(.refresh)
            let feedBefore = core.model.feedStories.map(\.id)
            let frontPageBefore = calls.frontPageCalls.count

            await commitSearch("rust", core: core, clock: clock, isolation: actor)
            let model = core.model
            #expect(model.searchResults.map(\.id) == ["100"])
            model.searchQuery = ""
            await waitUntil { model.searchLoaded == nil }

            #expect(model.searchResults.isEmpty)
            #expect(model.searchInitialStatus.error == nil)
            #expect(model.searchInitialStatus.isLoading == false)
            #expect(model.searchLoaded == nil)
            #expect(model.feedStories.map(\.id) == feedBefore)

            let frontPageAfter = calls.frontPageCalls.count
            #expect(frontPageAfter == frontPageBefore)
            let searchCalls = calls.searchCalls
            #expect(searchCalls.map(\.0) == ["rust"])
        }
    }

    @Test("feed survives an active search")
    func feedSurvivesActiveSearch() async throws {
        let clock = TestClock<Duration>()
        try await withCore(
            client: .mock(
                frontPage: { _ in page([storyA, storyB]) },
                search: { _, _ in page([storyA]) }
            ),
            clock: clock
        ) { actor, core in
            await core.sendMessage(.refresh)
            let feedSnapshot = core.model.feedStories.map(\.id)
            #expect(feedSnapshot == ["100", "101"])

            await commitSearch("x", core: core, clock: clock, isolation: actor)

            let model = core.model
            #expect(model.searchResults.map(\.id) == ["100"])
            #expect(model.feedStories.map(\.id) == feedSnapshot)
        }
    }

    @Test("backspacing all the way to empty during an in-flight fetch still clears results")
    func listener_burstWriteDuringFetchClearsResults() async throws {
        let calls = CallRecorder()
        let clock = TestClock<Duration>()
        try await withCore(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            clock: clock
        ) { actor, core in
            core.model.searchQuery = "rust"
            await waitUntil { core.model.searchInitialStatus.isLoading }

            // Backspace to empty before the debounce elapses: the listener cancels
            // the in-flight "rust" fetch (still parked on its sleep, never reaching
            // the client) and resets the status.
            core.model.searchQuery = ""
            await waitUntil { !core.model.searchInitialStatus.isLoading }

            let model = core.model
            #expect(model.searchResults.isEmpty)
            #expect(model.searchInitialStatus.error == nil)
            #expect(model.searchInitialStatus.isLoading == false)
            let recorded = calls.searchCalls
            #expect(recorded.map(\.0) == [])
        }
    }

    @Test("rapid keystrokes within the debounce window collapse to one search")
    func listener_rapidKeystrokes_onlyFinalQueryFires() async throws {
        let calls = CallRecorder()
        let clock = TestClock<Duration>()
        try await withCore(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            clock: clock
        ) { actor, core in
            // Let the listener suspend on `for await` before the first write.
            await settle(actor)

            core.model.searchQuery = "r"
            await settle(actor)
            core.model.searchQuery = "ru"
            await settle(actor)
            core.model.searchQuery = "rust"
            await settle(actor)

            await clock.advance(by: Core.searchDebounce)
            await settle(actor)

            let recorded = calls.searchCalls
            #expect(recorded.map(\.0) == ["rust"])
            #expect(core.model.searchResults.map(\.id) == ["100"])
        }
    }

    @Test("a story present in both feed and search shares its read state across projections")
    func storyInBothFeedAndSearch_sharesReadState() async throws {
        let clock = TestClock<Duration>()
        try await withCore(
            client: .mock(
                frontPage: { _ in page([storyA, storyB]) },
                search: { _, _ in page([storyA]) }
            ),
            clock: clock
        ) { actor, core in
            let model = core.model
            await core.sendMessage(.refresh)
            await core.sendMessage(.toggleRead(id: storyA.id))
            #expect(model.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)

            await commitSearch("x", core: core, clock: clock, isolation: actor)

            #expect(model.searchResults.first?.isRead == true)
        }
    }

    // MARK: Pagination

    @Test("loadMore appends page-1 ids to the snapshot and bumps the cursor")
    func loadMore_appendsAndBumpsCursor() async throws {
        try await withCore(
            client: .mock(
                frontPage: { p in
                    if p == 0 { return page([storyA, storyB], totalPages: 3) }
                    if p == 1 { return page([storyC], totalPages: 3) }
                    return page([])
                }
            )
        ) { _, core in
            let model = core.model
            await core.sendMessage(.refresh)
            #expect(model.feedLoaded?.page == 0)
            #expect(model.feedLoaded?.hasMore == true)
            #expect(model.feedStories.map(\.id) == ["100", "101"])

            await core.sendMessage(.loadMore)
            #expect(model.feedLoaded?.page == 1)
            #expect(model.feedLoaded?.hasMore == true)
            #expect(model.feedStories.map(\.id) == ["100", "101", "102"])
        }
    }

    @Test("loadMore on the last page is a no-op")
    func loadMore_onLastPage_isNoop() async throws {
        let calls = CallRecorder()
        try await withCore(
            client: .mock(
                frontPage: { p in
                    calls.recordFrontPage(page: p)
                    return page([storyA], totalPages: 1)
                }
            )
        ) { _, core in
            let model = core.model
            await core.sendMessage(.refresh)
            #expect(model.feedLoaded?.hasMore == false)
            await core.sendMessage(.loadMore)

            let pages = calls.frontPageCalls
            #expect(pages == [0])
        }
    }

    @Test("loadMore before any initial fetch is a no-op")
    func loadMore_withoutInitial_isNoop() async throws {
        let calls = CallRecorder()
        try await withCore(
            client: .mock(
                frontPage: { p in
                    calls.recordFrontPage(page: p)
                    return page([storyA])
                }
            )
        ) { _, core in
            await core.sendMessage(.loadMore)
            let pages = calls.frontPageCalls
            #expect(pages.isEmpty)
        }
    }

    @Test("refresh during an in-flight loadMore cancels the loadMore")
    func refresh_duringLoadMore_cancelsLoadMore() async throws {
        let calls = CallRecorder()
        let clock = TestClock<Duration>()
        try await withCore(
            client: .mock(
                frontPage: { p in
                    calls.recordFrontPage(page: p)
                    if p == 1 {
                        try await clock.sleep(for: .seconds(Int.max))
                    }
                    return page([storyA], totalPages: 5)
                }
            ),
            clock: clock
        ) { actor, core in
            let model = core.model
            await core.sendMessage(.refresh)
            #expect(model.feedLoaded?.page == 0)

            let loadMore = Task { _ = actor; await core.sendMessage(.loadMore) }
            await waitUntil { model.feedLoadMoreStatus.isLoading }
            #expect(model.feedLoadMoreStatus.isLoading == true)

            await core.sendMessage(.refresh)
            await loadMore.value

            #expect(model.feedLoaded?.page == 0)
            #expect(model.feedLoadMoreStatus.isLoading == false)
            #expect(model.feedLoadMoreStatus.error == nil)
        }
    }

    @Test("loadMore failure leaves the snapshot and initial status untouched")
    func loadMore_failure_isolatedToLoadMoreStatus() async throws {
        struct Boom: Error {}
        try await withCore(
            client: .mock(
                frontPage: { p in
                    if p == 0 { return page([storyA, storyB], totalPages: 5) }
                    throw Boom()
                }
            )
        ) { _, core in
            let model = core.model
            await core.sendMessage(.refresh)
            let before = model.feedStories.map(\.id)
            await core.sendMessage(.loadMore)
            #expect(model.feedStories.map(\.id) == before)
            #expect(model.feedInitialStatus.error == nil)
            #expect(model.feedLoadMoreStatus.error != nil)
        }
    }

    @Test("search paginates symmetrically with feed")
    func search_paginates() async throws {
        let clock = TestClock<Duration>()
        try await withCore(
            client: .mock(
                search: { _, p in
                    if p == 0 { return page([storyA], totalPages: 2) }
                    if p == 1 { return page([storyB], totalPages: 2) }
                    return page([])
                }
            ),
            clock: clock
        ) { actor, core in
            await commitSearch("x", core: core, clock: clock, isolation: actor)
            let model = core.model
            #expect(model.searchResults.map(\.id) == ["100"])
            #expect(model.searchLoaded?.hasMore == true)

            await core.sendMessage(.loadMore)
            #expect(model.searchResults.map(\.id) == ["100", "101"])
            #expect(model.searchLoaded?.hasMore == false)
        }
    }

    @Test("clearing search cancels in-flight search load-more")
    func clearSearch_cancelsLoadMore() async throws {
        let clock = TestClock<Duration>()
        try await withCore(
            client: .mock(
                search: { _, p in
                    if p == 0 { return page([storyA], totalPages: 5) }
                    try await clock.sleep(for: .seconds(Int.max))
                    return page([])
                }
            ),
            clock: clock
        ) { actor, core in
            await commitSearch("x", core: core, clock: clock, isolation: actor)
            #expect(core.model.searchLoaded?.hasMore == true)

            let loadMore = Task { _ = actor; await core.sendMessage(.loadMore) }
            await waitUntil { core.model.searchLoadMoreStatus.isLoading }
            #expect(core.model.searchLoadMoreStatus.isLoading == true)

            core.model.searchQuery = ""
            await loadMore.value
            await waitUntil { core.model.searchLoaded == nil }

            let model = core.model
            #expect(model.searchLoaded == nil)
            #expect(model.searchLoadMoreStatus.isLoading == false)
            #expect(model.searchLoadMoreStatus.error == nil)
        }
    }

    @Test("loadMore preserves loadedAt from the initial fetch")
    func loadMore_preservesLoadedAt() async throws {
        // Monotonic `now`: a wrongly-reassigned `loadedAt` would differ deterministically.
        let counter = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)
        try await withCore(
            client: .mock(
                frontPage: { p in
                    if p == 0 { return page([storyA], totalPages: 2) }
                    return page([storyB], totalPages: 2)
                }
            ),
            now: { counter.withLock { $0 += 1; return Date(timeIntervalSince1970: $0) } }
        ) { _, core in
            let model = core.model
            await core.sendMessage(.refresh)
            let initialLoadedAt = model.feedLoaded?.loadedAt
            await core.sendMessage(.loadMore)
            #expect(model.feedLoaded?.loadedAt == initialLoadedAt)
        }
    }
}
