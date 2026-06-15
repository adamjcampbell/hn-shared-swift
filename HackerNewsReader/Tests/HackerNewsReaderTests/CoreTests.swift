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

/// Drives the listener search to commit. Assumes the fixture's
/// zero-debounce default, so the fetch runs straight through its sleep
/// and the commit is the one transition to wait on. Inline the steps
/// instead when asserting mid-flight.
private func commitSearch(
    _ query: String,
    core: Core,
    isolation: isolated any Actor = #isolation
) async {
    core.model.searchQuery = query
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

    @Test("listener fires the search with the current query")
    func listener_firesWithCurrentQuery() async throws {
        let calls = CallRecorder()
        try await withCore(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            )
        ) { _, core in
            await commitSearch("rust", core: core)

            let model = core.model
            #expect(model.searchQuery == "rust")
            #expect(model.searchInitialStatus.isLoading == false)
            #expect(model.searchResults.map(\.id) == ["100"])

            let recorded = calls.searchCalls
            #expect(recorded.map(\.0) == ["rust"])
            #expect(recorded.map(\.1) == [0])
        }
    }

    @Test("initialStatus.isLoading activates on first keystroke, while the debounce is still pending")
    func isSearchLoading_activatesOnFirstKeystroke() async throws {
        let calls = CallRecorder()
        try await withCore(
            client: .mock(search: { query, p in
                calls.recordSearch(query, page: p)
                return page([storyA])
            }),
            debounce: debounceNeverElapses
        ) { _, core in
            let model = core.model
            #expect(model.searchInitialStatus.isLoading == false)
            model.searchQuery = "r"
            await waitUntil { model.searchInitialStatus.isLoading }

            // The window can't elapse: loading is live while the fetch is
            // still parked in its debounce, before the client is touched.
            #expect(model.searchLoaded == nil)
            #expect(calls.searchCalls.isEmpty)
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
        let gate = Gate()
        try await withCore(
            client: .mock(
                search: { query, _ in
                    if query == "ru" {
                        // Park mid-call; cancellation unparks, and the mock
                        // surfaces it the way URLSession does.
                        await gate.arrive()
                        throw URLError(.cancelled)
                    }
                    return page([storyA])
                }
            )
        ) { _, core in
            core.model.searchQuery = "ru"
            // The "ru" fetch is deterministically inside the client call.
            await gate.arrival()

            // The listener cancels "ru" mid-client-call (the URLError path
            // under test) and replaces it; the "rust" fetch commits.
            core.model.searchQuery = "rust"
            await waitUntil { core.model.searchLoaded != nil }

            let model = core.model
            #expect(model.searchInitialStatus.error == nil)
            #expect(model.searchQuery == "rust")
            #expect(model.searchResults.map(\.id) == ["100"])
        }
    }

    @Test("clearing the search query cancels the search, clears results, and does not refetch the feed")
    func clearingSearchQuery_cancelsAndClearsResults() async throws {
        let calls = CallRecorder()
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
            )
        ) { _, core in
            await core.sendMessage(.refresh)
            let feedBefore = core.model.feedStories.map(\.id)
            let frontPageBefore = calls.frontPageCalls.count

            await commitSearch("rust", core: core)
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
        try await withCore(
            client: .mock(
                frontPage: { _ in page([storyA, storyB]) },
                search: { _, _ in page([storyA]) }
            )
        ) { _, core in
            await core.sendMessage(.refresh)
            let feedSnapshot = core.model.feedStories.map(\.id)
            #expect(feedSnapshot == ["100", "101"])

            await commitSearch("x", core: core)

            let model = core.model
            #expect(model.searchResults.map(\.id) == ["100"])
            #expect(model.feedStories.map(\.id) == feedSnapshot)
        }
    }

    @Test("backspacing all the way to empty during an in-flight fetch still clears results")
    func listener_burstWriteDuringFetchClearsResults() async throws {
        let calls = CallRecorder()
        try await withCore(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            debounce: debounceNeverElapses
        ) { _, core in
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

    @Test("while the debounce window stays open, keystrokes don't reach the client and loading stays active")
    func searchKeystrokesWithinWindowDontReachClient() async throws {
        let calls = CallRecorder()
        try await withCore(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            debounce: debounceNeverElapses
        ) { _, core in
            let model = core.model
            model.searchQuery = "r"
            await waitUntil { model.searchInitialStatus.isLoading }

            model.searchQuery = "ru"
            model.searchQuery = "rust"

            // The window never elapses, so every superseded reload dies in
            // its debounce before touching the client; the latest keystroke
            // stays loading and nothing commits. Cancel-and-replace reaching
            // the client is covered by the zero-debounce URLError test.
            await waitUntil { model.searchQuery == "rust" }
            #expect(calls.searchCalls.isEmpty)
            #expect(model.searchInitialStatus.isLoading)
            #expect(model.searchLoaded == nil)
        }
    }

    @Test("a story present in both feed and search shares its read state across projections")
    func storyInBothFeedAndSearch_sharesReadState() async throws {
        try await withCore(
            client: .mock(
                frontPage: { _ in page([storyA, storyB]) },
                search: { _, _ in page([storyA]) }
            )
        ) { _, core in
            let model = core.model
            await core.sendMessage(.refresh)
            await core.sendMessage(.toggleRead(id: storyA.id))
            #expect(model.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)

            await commitSearch("x", core: core)

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
        let gate = Gate()
        try await withCore(
            client: .mock(
                frontPage: { p in
                    calls.recordFrontPage(page: p)
                    if p == 1 {
                        await gate.arrive()
                        try Task.checkCancellation()
                    }
                    return page([storyA], totalPages: 5)
                }
            )
        ) { actor, core in
            let model = core.model
            await core.sendMessage(.refresh)
            #expect(model.feedLoaded?.page == 0)

            let loadMore = Task { _ = actor; await core.sendMessage(.loadMore) }
            // The page-1 fetch is deterministically inside the client call.
            await gate.arrival()
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
        try await withCore(
            client: .mock(
                search: { _, p in
                    if p == 0 { return page([storyA], totalPages: 2) }
                    if p == 1 { return page([storyB], totalPages: 2) }
                    return page([])
                }
            )
        ) { _, core in
            await commitSearch("x", core: core)
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
        let gate = Gate()
        try await withCore(
            client: .mock(
                search: { _, p in
                    if p == 0 { return page([storyA], totalPages: 5) }
                    await gate.arrive()
                    try Task.checkCancellation()
                    return page([])
                }
            )
        ) { actor, core in
            await commitSearch("x", core: core)
            #expect(core.model.searchLoaded?.hasMore == true)

            let loadMore = Task { _ = actor; await core.sendMessage(.loadMore) }
            // The page-1 fetch is deterministically inside the client call.
            await gate.arrival()
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

    @Test("a search load-more that completes after a new query supersedes it does not corrupt the new results")
    func searchLoadMore_completingAfterSupersede_doesNotCorrupt() async throws {
        // Models cancel losing the race: the page-1 fetch's round-trip finishes
        // *after* the new query cancels it, so the slot would deliver a value.
        let hold = Hold()
        try await withCore(
            client: .mock(
                search: { query, p in
                    if query == "rust" && p == 1 {
                        await hold.wait()
                        return page([storyC], totalPages: 5)
                    }
                    if query == "go" { return page([storyB], totalPages: 1) }
                    return page([storyA], totalPages: 5)
                }
            )
        ) { actor, core in
            let model = core.model
            await commitSearch("rust", core: core)
            #expect(model.searchResults.map(\.id) == ["100"])

            let loadMore = Task { _ = actor; await core.sendMessage(.loadMore) }
            await hold.arrival()                       // the rust page-1 fetch is in flight

            model.searchQuery = "go"                    // supersede: cancels the search load-more
            await waitUntil { model.searchResults.map(\.id) == ["101"] }

            hold.release()                              // rust page-1 returns despite the cancel
            await loadMore.value

            #expect(model.searchQuery == "go")
            #expect(model.searchResults.map(\.id) == ["101"])   // not ["101", "102"]
            #expect(model.searchLoaded?.page == 0)               // cursor not bumped
        }
    }

    @Test("a feed load-more that completes after a refresh supersedes it does not append onto the refreshed snapshot")
    func feedLoadMore_completingAfterRefresh_doesNotCorrupt() async throws {
        let hold = Hold()
        try await withCore(
            client: .mock(
                frontPage: { p in
                    if p == 1 {
                        await hold.wait()
                        return page([storyC], totalPages: 5)
                    }
                    return page([storyA], totalPages: 5)
                }
            )
        ) { actor, core in
            let model = core.model
            await core.sendMessage(.refresh)
            #expect(model.feedStories.map(\.id) == ["100"])

            let loadMore = Task { _ = actor; await core.sendMessage(.loadMore) }
            await hold.arrival()                        // the page-1 fetch is in flight

            await core.sendMessage(.refresh)             // supersede: shares the feed slot
            #expect(model.feedStories.map(\.id) == ["100"])

            hold.release()                               // page-1 returns despite the cancel
            await loadMore.value

            #expect(model.feedStories.map(\.id) == ["100"])   // not ["100", "102"]
            #expect(model.feedLoaded?.page == 0)               // cursor not bumped
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
