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
private let commentA = Comment(
    id: "200", author: "dave", text: "First comment",
    createdAt: Date(timeIntervalSince1970: 4), depth: 0
)
private let commentB = Comment(
    id: "201", author: "erin", text: "Nested comment",
    createdAt: Date(timeIntervalSince1970: 5), depth: 1
)

/// Records the queries (and pages) the mock client was called with.
private struct CallRecorder {
    private struct State {
        var frontPageCalls: [Int] = []
        var searchCalls: [(String, Int)] = []
        var commentsCalls: [String] = []
    }
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    var frontPageCalls: [Int] { lock.withLock { $0.frontPageCalls } }
    var searchCalls: [(String, Int)] { lock.withLock { $0.searchCalls } }
    var commentsCalls: [String] { lock.withLock { $0.commentsCalls } }

    func recordFrontPage(page: Int) { lock.withLock { $0.frontPageCalls.append(page) } }
    func recordSearch(_ query: String, page: Int) { lock.withLock { $0.searchCalls.append((query, page)) } }
    func recordComments(storyID: String) { lock.withLock { $0.commentsCalls.append(storyID) } }
}

/// Strictly-increasing Date source; `next()` yields a later Date each call.
private struct MonotonicDates {
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

/// Drive the listener-debounced search to commit. Inline the steps
/// instead when asserting mid-flight. Requires the test's `Engine`
/// to hold a `TestClock`; `#require` throws otherwise.
private func commitSearch(_ query: String, on engine: Engine) async throws {
    try await engine.testActor.runPending()
    await engine.run { core in core.model.searchQuery = query }
    try await engine.testActor.runPending()
    try await engine.testClock.advance(by: Engine.searchDebounce)
    try await engine.testActor.runPending()
}

@Suite("Core")
struct CoreTests {

    @Test("refresh populates feed stories and timestamp")
    func refresh_populatesStoriesAndTimestamp() async throws {
        try await withEngine(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { engine in
            await engine.run { engine in
                let model = engine.model
                #expect(model.feedStories.isEmpty)
                #expect(model.feedLoaded == nil)

                await engine.sendMessage(.refresh)

                #expect(model.feedStories.count == 2)
                #expect(model.feedStories.first?.title == "Top story")
                #expect(model.feedLoaded?.loadedAt != nil)
                #expect(model.feedInitialStatus.error == nil)
            }
        }
    }

    @Test("refresh records initialStatus.error on failure")
    func refresh_recordsErrorOnFailure() async throws {
        struct Boom: Error {}
        try await withEngine(
            client: .mock(
                frontPage: { _ in throw Boom() },
                search: { _, _ in throw Boom() }
            )
        ) { engine in
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.refresh)
                #expect(model.feedStories.isEmpty)
                #expect(model.feedInitialStatus.error != nil)
            }
        }
    }

    @Test("toggleRead adds and removes")
    func toggleRead_addsAndRemoves() async throws {
        try await withEngine(
            client: .mock(frontPage: { _ in page([storyA]) })
        ) { engine in
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.refresh)
                #expect(model.feedStories.first?.isRead == false)

                await engine.sendMessage(.toggleRead(id: storyA.id))
                #expect(model.feedStories.first?.isRead == true)
                #expect(model.readIds.contains(storyA.id))

                await engine.sendMessage(.toggleRead(id: storyA.id))
                #expect(model.feedStories.first?.isRead == false)
                #expect(model.readIds.contains(storyA.id) == false)
            }
        }
    }

    @Test("viewStory marks read without emitting a URL command")
    func viewStory_marksReadOnly() async throws {
        try await withEngine(
            client: .mock(frontPage: { _ in page([storyA, storyC]) })
        ) { engine in
            await engine.run { await $0.sendMessage(.refresh) }

            var iterator = engine.commands.makeAsyncIterator()
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.viewStory(id: storyA.id))
                #expect(model.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)
                await engine.sendMessage(.openStoryURL(id: storyC.id))
            }
            let command = await iterator.next()
            #expect(command == .presentURL(value: storyC.url!))
        }
    }

    @Test("openStoryURL marks read and emits presentURL command")
    func openStoryURL_marksReadAndEmitsPresentURL() async throws {
        try await withEngine(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { engine in
            await engine.run { await $0.sendMessage(.refresh) }

            var iterator = engine.commands.makeAsyncIterator()
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.openStoryURL(id: storyA.id))
                #expect(model.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)
            }
            let command = await iterator.next()
            #expect(command == .presentURL(value: storyA.url!))
        }
    }

    @Test("openStoryURL on a story without a URL marks read but emits nothing")
    func openStoryURL_withoutURL_marksReadOnly() async throws {
        try await withEngine(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { engine in
            await engine.run { await $0.sendMessage(.refresh) }

            var iterator = engine.commands.makeAsyncIterator()
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.openStoryURL(id: storyB.id))
                await engine.sendMessage(.openStoryURL(id: storyA.id))
                #expect(model.feedStories.first(where: { $0.id == storyB.id })?.isRead == true)
            }
            let command = await iterator.next()
            #expect(command == .presentURL(value: storyA.url!))
        }
    }

    @Test("story actions with unknown ids are no-ops")
    func storyActions_unknownId_areNoops() async throws {
        try await withEngine(
            client: .mock(frontPage: { _ in page([storyA]) })
        ) { engine in
            var iterator = engine.commands.makeAsyncIterator()
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.refresh)
                let readBefore = model.readIds
                await engine.sendMessage(.viewStory(id: "does-not-exist"))
                await engine.sendMessage(.openStoryURL(id: "does-not-exist"))
                await engine.sendMessage(.openStoryURL(id: storyA.id))
                #expect(model.readIds == readBefore.union([storyA.id]))
            }
            let command = await iterator.next()
            #expect(command == .presentURL(value: storyA.url!))
        }
    }

    @Test("loadComments populates comment rows and status")
    func loadComments_populatesRowsAndStatus() async throws {
        try await withEngine(
            client: .mock(
                frontPage: { _ in page([storyA]) },
                comments: { id in
                    #expect(id == storyA.id)
                    return [commentA, commentB]
                }
            )
        ) { engine in
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.refresh)
                await engine.sendMessage(.loadComments(id: storyA.id))

                #expect(model.commentRows(storyID: storyA.id).map(\.id) == ["200", "201"])
                #expect(model.commentRows(storyID: storyA.id).map(\.depth) == [0, 1])
                #expect(model.commentsStatus(storyID: storyA.id).isLoading == false)
                #expect(model.commentsStatus(storyID: storyA.id).error == nil)
            }
        }
    }

    @Test("loadComments is idempotent once comments are loaded")
    func loadComments_loadedStoryDoesNotRefetch() async throws {
        let calls = CallRecorder()
        try await withEngine(
            client: .mock(
                frontPage: { _ in page([storyA]) },
                comments: { id in
                    calls.recordComments(storyID: id)
                    return [commentA]
                }
            )
        ) { engine in
            await engine.run { engine in
                await engine.sendMessage(.refresh)
                await engine.sendMessage(.loadComments(id: storyA.id))
                await engine.sendMessage(.loadComments(id: storyA.id))
            }
            #expect(calls.commentsCalls == [storyA.id])
        }
    }

    @Test("loadComments records an error on failure")
    func loadComments_recordsErrorOnFailure() async throws {
        struct Boom: Error {}
        try await withEngine(
            client: .mock(
                frontPage: { _ in page([storyA]) },
                comments: { _ in throw Boom() }
            )
        ) { engine in
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.refresh)
                await engine.sendMessage(.loadComments(id: storyA.id))
                #expect(model.commentRows(storyID: storyA.id).isEmpty)
                #expect(model.commentsStatus(storyID: storyA.id).isLoading == false)
                #expect(model.commentsStatus(storyID: storyA.id).error != nil)
            }
        }
    }

    @Test("read state survives a refresh")
    func toggleRead_survivesRefresh() async throws {
        try await withEngine(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { engine in
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.toggleRead(id: "100"))
                #expect(model.readIds.contains("100"))
                #expect(model.feedStories.isEmpty)

                await engine.sendMessage(.refresh)
                let projected = model.feedStories.first(where: { $0.id == "100" })
                #expect(projected != nil)
                #expect(projected?.isRead == true)
            }
        }
    }

    @Test("listener debounces and fires search with current query")
    func listener_debouncesAndFires() async throws {
        let calls = CallRecorder()
        try await withEngine(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            clock: TestClock()
        ) { engine in
            try await commitSearch("rust", on: engine)

            await engine.run { engine in
                let model = engine.model
                #expect(model.searchQuery == "rust")
                #expect(model.searchResults.map(\.id) == ["100"])
            }
            let recorded = calls.searchCalls
            #expect(recorded.map(\.0) == ["rust"])
            #expect(recorded.map(\.1) == [0])
        }
    }

    @Test("initialStatus.isLoading activates on first keystroke, before debounce elapses")
    func isSearchLoading_activatesOnFirstKeystroke() async throws {
        try await withEngine(
            client: .mock(search: { _, _ in page([storyA]) }),
            clock: TestClock()
        ) { engine in
            try await engine.testActor.runPending()
            await engine.run { engine in
                let model = engine.model
                #expect(model.searchInitialStatus.isLoading == false)
                model.searchQuery = "r"
            }
            try await engine.testActor.runPending()

            await engine.run { engine in #expect(engine.model.searchInitialStatus.isLoading == true) }

            try await engine.testClock.advance(by: Engine.searchDebounce)
            try await engine.testActor.runPending()

            await engine.run { engine in #expect(engine.model.searchInitialStatus.isLoading == false) }
        }
    }

    @Test("URLError(.cancelled) from a cancelled feed fetch is treated as cancellation")
    func cancelledURLError_doesNotSurfaceAsFeedLoadError() async throws {
        // URLSession surfaces task cancellation as URLError.cancelled, not CancellationError.
        try await withEngine(
            client: .mock(
                frontPage: { _ in throw URLError(.cancelled) },
                search:    { _, _ in throw URLError(.cancelled) }
            )
        ) { engine in
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.refresh)
                #expect(model.feedInitialStatus.error == nil)
                #expect(model.feedLoaded == nil)
            }
        }
    }

    @Test("search-to-search cancel-and-replace through URLError(.cancelled) doesn't surface")
    func searchCancelAndReplace_throughURLErrorCancelled_silent() async throws {
        let clock = TestClock()
        try await withEngine(
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
        ) { engine in
            try await engine.testActor.runPending()
            await engine.run { engine in engine.model.searchQuery = "ru" }
            try await engine.testActor.runPending()
            await clock.advance(by: Engine.searchDebounce)
            try await engine.testActor.runPending()

            await engine.run { engine in engine.model.searchQuery = "rust" }
            try await engine.testActor.runPending()
            await clock.advance(by: Engine.searchDebounce)
            try await engine.testActor.runPending()

            await engine.run { engine in
                let model = engine.model
                #expect(model.searchInitialStatus.error == nil)
                #expect(model.searchQuery == "rust")
                #expect(model.searchResults.map(\.id) == ["100"])
            }
        }
    }

    @Test("clearing the search query cancels the search, clears results, and does not refetch the feed")
    func clearingSearchQuery_cancelsAndClearsResults() async throws {
        let calls = CallRecorder()
        try await withEngine(
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
            clock: TestClock()
        ) { engine in
            let feedBefore = await engine.run { engine in
                await engine.sendMessage(.refresh)
                return engine.model.feedStories.map(\.id)
            }
            let frontPageBefore = calls.frontPageCalls.count

            try await commitSearch("rust", on: engine)
            await engine.run { engine in
                let model = engine.model
                #expect(model.searchResults.map(\.id) == ["100"])
                model.searchQuery = ""
            }
            try await engine.testActor.runPending()

            await engine.run { engine in
                let model = engine.model
                #expect(model.searchResults.isEmpty)
                #expect(model.searchInitialStatus.error == nil)
                #expect(model.searchInitialStatus.isLoading == false)
                #expect(model.searchLoaded == nil)
                #expect(model.feedStories.map(\.id) == feedBefore)
            }
            let frontPageAfter = calls.frontPageCalls.count
            #expect(frontPageAfter == frontPageBefore)
            let searchCalls = calls.searchCalls
            #expect(searchCalls.map(\.0) == ["rust"])
        }
    }

    @Test("feed survives an active search")
    func feedSurvivesActiveSearch() async throws {
        try await withEngine(
            client: .mock(
                frontPage: { _ in page([storyA, storyB]) },
                search: { _, _ in page([storyA]) }
            ),
            clock: TestClock()
        ) { engine in
            let feedSnapshot = await engine.run { engine in
                await engine.sendMessage(.refresh)
                return engine.model.feedStories.map(\.id)
            }
            #expect(feedSnapshot == ["100", "101"])

            try await commitSearch("x", on: engine)

            await engine.run { engine in
                let model = engine.model
                #expect(model.searchResults.map(\.id) == ["100"])
                #expect(model.feedStories.map(\.id) == feedSnapshot)
            }
        }
    }

    @Test("backspacing all the way to empty during an in-flight fetch still clears results")
    func listener_burstWriteDuringFetchClearsResults() async throws {
        let calls = CallRecorder()
        try await withEngine(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            clock: TestClock()
        ) { engine in
            // Let the listener suspend on `for await` before the first write.
            try await engine.testActor.runPending()

            await engine.run { engine in engine.model.searchQuery = "rust" }
            try await engine.testActor.runPending()

            await engine.run { engine in engine.model.searchQuery = "" }
            try await engine.testActor.runPending()

            try await engine.testClock.advance(by: Engine.searchDebounce)
            try await engine.testActor.runPending()

            await engine.run { engine in
                let model = engine.model
                #expect(model.searchResults.isEmpty)
                #expect(model.searchInitialStatus.error == nil)
                #expect(model.searchInitialStatus.isLoading == false)
            }
            let recorded = calls.searchCalls
            #expect(recorded.map(\.0) == [])
        }
    }

    @Test("rapid keystrokes within the debounce window collapse to one search")
    func listener_rapidKeystrokes_onlyFinalQueryFires() async throws {
        let calls = CallRecorder()
        try await withEngine(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            clock: TestClock()
        ) { engine in
            // Let the listener suspend on `for await` before the first write.
            try await engine.testActor.runPending()

            await engine.run { engine in engine.model.searchQuery = "r" }
            try await engine.testActor.runPending()
            await engine.run { engine in engine.model.searchQuery = "ru" }
            try await engine.testActor.runPending()
            await engine.run { engine in engine.model.searchQuery = "rust" }
            try await engine.testActor.runPending()

            try await engine.testClock.advance(by: Engine.searchDebounce)
            try await engine.testActor.runPending()

            let recorded = calls.searchCalls
            #expect(recorded.map(\.0) == ["rust"])
            await engine.run { engine in #expect(engine.model.searchResults.map(\.id) == ["100"]) }
        }
    }

    @Test("a story present in both feed and search shares its read state across projections")
    func storyInBothFeedAndSearch_sharesReadState() async throws {
        try await withEngine(
            client: .mock(
                frontPage: { _ in page([storyA, storyB]) },
                search: { _, _ in page([storyA]) }
            ),
            clock: TestClock()
        ) { engine in
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.refresh)
                await engine.sendMessage(.toggleRead(id: storyA.id))
                #expect(model.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)
            }

            try await commitSearch("x", on: engine)

            await engine.run { engine in #expect(engine.model.searchResults.first?.isRead == true) }
        }
    }

    // MARK: Pagination

    @Test("loadMore appends page-1 ids to the snapshot and bumps the cursor")
    func loadMore_appendsAndBumpsCursor() async throws {
        try await withEngine(
            client: .mock(
                frontPage: { p in
                    if p == 0 { return page([storyA, storyB], totalPages: 3) }
                    if p == 1 { return page([storyC], totalPages: 3) }
                    return page([])
                }
            )
        ) { engine in
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.refresh)
                #expect(model.feedLoaded?.page == 0)
                #expect(model.feedLoaded?.hasMore == true)
                #expect(model.feedStories.map(\.id) == ["100", "101"])

                await engine.sendMessage(.loadMore)
                #expect(model.feedLoaded?.page == 1)
                #expect(model.feedLoaded?.hasMore == true)
                #expect(model.feedStories.map(\.id) == ["100", "101", "102"])
            }
        }
    }

    @Test("loadMore on the last page is a no-op")
    func loadMore_onLastPage_isNoop() async throws {
        let calls = CallRecorder()
        try await withEngine(
            client: .mock(
                frontPage: { p in
                    calls.recordFrontPage(page: p)
                    return page([storyA], totalPages: 1)
                }
            )
        ) { engine in
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.refresh)
                #expect(model.feedLoaded?.hasMore == false)
                await engine.sendMessage(.loadMore)
            }
            let pages = calls.frontPageCalls
            #expect(pages == [0])
        }
    }

    @Test("loadMore before any initial fetch is a no-op")
    func loadMore_withoutInitial_isNoop() async throws {
        let calls = CallRecorder()
        try await withEngine(
            client: .mock(
                frontPage: { p in
                    calls.recordFrontPage(page: p)
                    return page([storyA])
                }
            )
        ) { engine in
            await engine.run { await $0.sendMessage(.loadMore) }
            let pages = calls.frontPageCalls
            #expect(pages.isEmpty)
        }
    }

    @Test("refresh during an in-flight loadMore cancels the loadMore")
    func refresh_duringLoadMore_cancelsLoadMore() async throws {
        let calls = CallRecorder()
        let clock = TestClock()
        try await withEngine(
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
        ) { engine in
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.refresh)
                #expect(model.feedLoaded?.page == 0)
            }

            let loadMore = Task { [engine] in
                await engine.run { await $0.sendMessage(.loadMore) }
            }
            try await engine.testActor.runPending()
            await engine.run { engine in #expect(engine.model.feedLoadMoreStatus.isLoading == true) }

            await engine.run { await $0.sendMessage(.refresh) }
            await loadMore.value

            await engine.run { engine in
                let model = engine.model
                #expect(model.feedLoaded?.page == 0)
                #expect(model.feedLoadMoreStatus.isLoading == false)
                #expect(model.feedLoadMoreStatus.error == nil)
            }
        }
    }

    @Test("loadMore failure leaves the snapshot and initial status untouched")
    func loadMore_failure_isolatedToLoadMoreStatus() async throws {
        struct Boom: Error {}
        try await withEngine(
            client: .mock(
                frontPage: { p in
                    if p == 0 { return page([storyA, storyB], totalPages: 5) }
                    throw Boom()
                }
            )
        ) { engine in
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.refresh)
                let before = model.feedStories.map(\.id)
                await engine.sendMessage(.loadMore)
                #expect(model.feedStories.map(\.id) == before)
                #expect(model.feedInitialStatus.error == nil)
                #expect(model.feedLoadMoreStatus.error != nil)
            }
        }
    }

    @Test("search paginates symmetrically with feed")
    func search_paginates() async throws {
        try await withEngine(
            client: .mock(
                search: { _, p in
                    if p == 0 { return page([storyA], totalPages: 2) }
                    if p == 1 { return page([storyB], totalPages: 2) }
                    return page([])
                }
            ),
            clock: TestClock()
        ) { engine in
            try await commitSearch("x", on: engine)
            await engine.run { engine in
                let model = engine.model
                #expect(model.searchResults.map(\.id) == ["100"])
                #expect(model.searchLoaded?.hasMore == true)

                await engine.sendMessage(.loadMore)
                #expect(model.searchResults.map(\.id) == ["100", "101"])
                #expect(model.searchLoaded?.hasMore == false)
            }
        }
    }

    @Test("clearing search cancels in-flight search load-more")
    func clearSearch_cancelsLoadMore() async throws {
        let clock = TestClock()
        try await withEngine(
            client: .mock(
                search: { _, p in
                    if p == 0 { return page([storyA], totalPages: 5) }
                    try await clock.sleep(for: .seconds(Int.max))
                    return page([])
                }
            ),
            clock: clock
        ) { engine in
            try await commitSearch("x", on: engine)
            await engine.run { engine in #expect(engine.model.searchLoaded?.hasMore == true) }

            let loadMore = Task { [engine] in
                await engine.run { await $0.sendMessage(.loadMore) }
            }
            try await engine.testActor.runPending()
            await engine.run { engine in #expect(engine.model.searchLoadMoreStatus.isLoading == true) }

            await engine.run { engine in engine.model.searchQuery = "" }
            await loadMore.value
            try await engine.testActor.runPending()

            await engine.run { engine in
                let model = engine.model
                #expect(model.searchLoaded == nil)
                #expect(model.searchLoadMoreStatus.isLoading == false)
                #expect(model.searchLoadMoreStatus.error == nil)
            }
        }
    }

    @Test("loadMore preserves loadedAt from the initial fetch")
    func loadMore_preservesLoadedAt() async throws {
        // Monotonic `now`: a wrongly-reassigned `loadedAt` would differ deterministically.
        let dates = MonotonicDates()
        try await withEngine(
            client: .mock(
                frontPage: { p in
                    if p == 0 { return page([storyA], totalPages: 2) }
                    return page([storyB], totalPages: 2)
                }
            ),
            now: dates.next
        ) { engine in
            await engine.run { engine in
                let model = engine.model
                await engine.sendMessage(.refresh)
                let initialLoadedAt = model.feedLoaded?.loadedAt
                await engine.sendMessage(.loadMore)
                #expect(model.feedLoaded?.loadedAt == initialLoadedAt)
            }
        }
    }
}
