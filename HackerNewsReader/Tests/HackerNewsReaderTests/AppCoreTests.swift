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
/// instead when asserting mid-flight. Requires the test's `AppCore`
/// to hold a `TestClock`; `#require` throws otherwise.
private func commitSearch(_ query: String, on appCore: AppCore) async throws {
    try await appCore.testActor.runPending()
    await appCore.run { core in core.state.searchQuery = query }
    try await appCore.testActor.runPending()
    try await appCore.testClock.advance(by: AppCore.searchDebounce)
    try await appCore.testActor.runPending()
}

@Suite("AppCore")
struct AppCoreTests {

    @Test("refresh populates feed stories and timestamp")
    func refresh_populatesStoriesAndTimestamp() async throws {
        try await withAppCore(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { appCore in
            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.feedStories.isEmpty)
                #expect(state.feedLoaded == nil)

                await appCore.sendEvent(.refresh)

                #expect(state.feedStories.count == 2)
                #expect(state.feedStories.first?.title == "Top story")
                #expect(state.feedLoaded?.loadedAt != nil)
                #expect(state.feedInitialStatus.error == nil)
            }
        }
    }

    @Test("refresh records initialStatus.error on failure")
    func refresh_recordsErrorOnFailure() async throws {
        struct Boom: Error {}
        try await withAppCore(
            client: .mock(
                frontPage: { _ in throw Boom() },
                search: { _, _ in throw Boom() }
            )
        ) { appCore in
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                #expect(state.feedStories.isEmpty)
                #expect(state.feedInitialStatus.error != nil)
            }
        }
    }

    @Test("toggleRead adds and removes")
    func toggleRead_addsAndRemoves() async throws {
        try await withAppCore(
            client: .mock(frontPage: { _ in page([storyA]) })
        ) { appCore in
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                #expect(state.feedStories.first?.isRead == false)

                await appCore.sendEvent(.toggleRead(id: storyA.id))
                #expect(state.feedStories.first?.isRead == true)
                #expect(state.readIds.contains(storyA.id))

                await appCore.sendEvent(.toggleRead(id: storyA.id))
                #expect(state.feedStories.first?.isRead == false)
                #expect(state.readIds.contains(storyA.id) == false)
            }
        }
    }

    @Test("openStory marks read and emits presentURL command")
    func openStory_marksReadAndEmitsPresentURL() async throws {
        try await withAppCore(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { appCore in
            await appCore.run { await $0.sendEvent(.refresh) }

            var iterator = appCore.commands.makeAsyncIterator()
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.openStory(id: storyA.id))
                #expect(state.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)
            }
            let command = await iterator.next()
            #expect(command == .presentURL(value: storyA.url!))
        }
    }

    @Test("openStory on a story without a URL marks read but emits nothing")
    func openStory_withoutURL_marksReadOnly() async throws {
        try await withAppCore(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { appCore in
            await appCore.run { await $0.sendEvent(.refresh) }

            // First emission we observe is storyA's — proving storyB emitted nothing.
            var iterator = appCore.commands.makeAsyncIterator()
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.openStory(id: storyB.id))
                await appCore.sendEvent(.openStory(id: storyA.id))
                #expect(state.feedStories.first(where: { $0.id == storyB.id })?.isRead == true)
            }
            let command = await iterator.next()
            #expect(command == .presentURL(value: storyA.url!))
        }
    }

    @Test("openStory with unknown id is a no-op")
    func openStory_unknownId_isNoop() async throws {
        try await withAppCore(
            client: .mock(frontPage: { _ in page([storyA]) })
        ) { appCore in
            var iterator = appCore.commands.makeAsyncIterator()
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                let readBefore = state.readIds
                await appCore.sendEvent(.openStory(id: "does-not-exist"))
                await appCore.sendEvent(.openStory(id: storyA.id))
                #expect(state.readIds == readBefore.union([storyA.id]))
            }
            let command = await iterator.next()
            #expect(command == .presentURL(value: storyA.url!))
        }
    }

    @Test("read state survives a refresh")
    func toggleRead_survivesRefresh() async throws {
        try await withAppCore(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { appCore in
            await appCore.run { appCore in
                let state = appCore.state
                // readIds is the canonical record; toggling before the projection has anything to map onto is fine.
                await appCore.sendEvent(.toggleRead(id: "100"))
                #expect(state.readIds.contains("100"))
                #expect(state.feedStories.isEmpty)

                await appCore.sendEvent(.refresh)
                let projected = state.feedStories.first(where: { $0.id == "100" })
                #expect(projected != nil)
                #expect(projected?.isRead == true)
            }
        }
    }

    @Test("listener debounces and fires search with current query")
    func listener_debouncesAndFires() async throws {
        let calls = CallRecorder()
        try await withAppCore(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            clock: TestClock()
        ) { appCore in
            try await commitSearch("rust", on: appCore)

            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchQuery == "rust")
                #expect(state.searchResults.map(\.id) == ["100"])
            }
            let recorded = calls.searchCalls
            #expect(recorded.map(\.0) == ["rust"])
            #expect(recorded.map(\.1) == [0])
        }
    }

    @Test("initialStatus.isLoading activates on first keystroke, before debounce elapses")
    func isSearchLoading_activatesOnFirstKeystroke() async throws {
        try await withAppCore(
            client: .mock(search: { _, _ in page([storyA]) }),
            clock: TestClock()
        ) { appCore in
            try await appCore.testActor.runPending()
            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchInitialStatus.isLoading == false)
                state.searchQuery = "r"
            }
            try await appCore.testActor.runPending()

            // Spinner is on before the debounce elapses.
            await appCore.run { appCore in #expect(appCore.state.searchInitialStatus.isLoading == true) }

            try await appCore.testClock.advance(by: AppCore.searchDebounce)
            try await appCore.testActor.runPending()

            await appCore.run { appCore in #expect(appCore.state.searchInitialStatus.isLoading == false) }
        }
    }

    @Test("URLError(.cancelled) from a cancelled feed fetch is treated as cancellation")
    func cancelledURLError_doesNotSurfaceAsFeedLoadError() async throws {
        // URLSession surfaces task cancellation as URLError.cancelled, not CancellationError.
        try await withAppCore(
            client: .mock(
                frontPage: { _ in throw URLError(.cancelled) },
                search:    { _, _ in throw URLError(.cancelled) }
            )
        ) { appCore in
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                #expect(state.feedInitialStatus.error == nil)
                #expect(state.feedLoaded == nil)
            }
        }
    }

    @Test("search-to-search cancel-and-replace through URLError(.cancelled) doesn't surface")
    func searchCancelAndReplace_throughURLErrorCancelled_silent() async throws {
        let clock = TestClock()
        try await withAppCore(
            client: .mock(
                search: { query, _ in
                    if query == "ru" {
                        // Park until cancelled, then surface URLError(.cancelled).
                        do { try await clock.sleep(for: .seconds(Int.max)) }
                        catch { throw URLError(.cancelled) }
                    }
                    return page([storyA])
                }
            ),
            clock: clock
        ) { appCore in
            try await appCore.testActor.runPending()
            await appCore.run { appCore in appCore.state.searchQuery = "ru" }
            try await appCore.testActor.runPending()
            await clock.advance(by: AppCore.searchDebounce)
            try await appCore.testActor.runPending()

            await appCore.run { appCore in appCore.state.searchQuery = "rust" }
            try await appCore.testActor.runPending()
            await clock.advance(by: AppCore.searchDebounce)
            try await appCore.testActor.runPending()

            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchInitialStatus.error == nil)
                #expect(state.searchQuery == "rust")
                #expect(state.searchResults.map(\.id) == ["100"])
            }
        }
    }

    @Test("clearing the search query cancels the search, clears results, and does not refetch the feed")
    func clearingSearchQuery_cancelsAndClearsResults() async throws {
        let calls = CallRecorder()
        try await withAppCore(
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
        ) { appCore in
            let feedBefore = await appCore.run { appCore in
                await appCore.sendEvent(.refresh)
                return appCore.state.feedStories.map(\.id)
            }
            let frontPageBefore = calls.frontPageCalls.count

            try await commitSearch("rust", on: appCore)
            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchResults.map(\.id) == ["100"])
                state.searchQuery = ""
            }
            try await appCore.testActor.runPending()

            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchResults.isEmpty)
                #expect(state.searchInitialStatus.error == nil)
                #expect(state.searchInitialStatus.isLoading == false)
                #expect(state.searchLoaded == nil)
                #expect(state.feedStories.map(\.id) == feedBefore)
            }
            let frontPageAfter = calls.frontPageCalls.count
            #expect(frontPageAfter == frontPageBefore)
            let searchCalls = calls.searchCalls
            #expect(searchCalls.map(\.0) == ["rust"])
        }
    }

    @Test("feed survives an active search")
    func feedSurvivesActiveSearch() async throws {
        try await withAppCore(
            client: .mock(
                frontPage: { _ in page([storyA, storyB]) },
                search: { _, _ in page([storyA]) }
            ),
            clock: TestClock()
        ) { appCore in
            let feedSnapshot = await appCore.run { appCore in
                await appCore.sendEvent(.refresh)
                return appCore.state.feedStories.map(\.id)
            }
            #expect(feedSnapshot == ["100", "101"])

            try await commitSearch("x", on: appCore)

            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchResults.map(\.id) == ["100"])
                #expect(state.feedStories.map(\.id) == feedSnapshot)
            }
        }
    }

    @Test("backspacing all the way to empty during an in-flight fetch still clears results")
    func listener_burstWriteDuringFetchClearsResults() async throws {
        let calls = CallRecorder()
        try await withAppCore(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            clock: TestClock()
        ) { appCore in
            // Let the listener reach its `for await` suspension before the first write.
            try await appCore.testActor.runPending()

            await appCore.run { appCore in appCore.state.searchQuery = "rust" }
            try await appCore.testActor.runPending()

            await appCore.run { appCore in appCore.state.searchQuery = "" }
            try await appCore.testActor.runPending()

            try await appCore.testClock.advance(by: AppCore.searchDebounce)
            try await appCore.testActor.runPending()

            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchResults.isEmpty)
                #expect(state.searchInitialStatus.error == nil)
                #expect(state.searchInitialStatus.isLoading == false)
            }
            let recorded = calls.searchCalls
            #expect(recorded.map(\.0) == [])
        }
    }

    @Test("rapid keystrokes within the debounce window collapse to one search")
    func listener_rapidKeystrokes_onlyFinalQueryFires() async throws {
        let calls = CallRecorder()
        try await withAppCore(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            clock: TestClock()
        ) { appCore in
            // Let the listener reach its `for await` suspension before the first write.
            try await appCore.testActor.runPending()

            await appCore.run { appCore in appCore.state.searchQuery = "r" }
            try await appCore.testActor.runPending()
            await appCore.run { appCore in appCore.state.searchQuery = "ru" }
            try await appCore.testActor.runPending()
            await appCore.run { appCore in appCore.state.searchQuery = "rust" }
            try await appCore.testActor.runPending()

            try await appCore.testClock.advance(by: AppCore.searchDebounce)
            try await appCore.testActor.runPending()

            let recorded = calls.searchCalls
            #expect(recorded.map(\.0) == ["rust"])
            await appCore.run { appCore in #expect(appCore.state.searchResults.map(\.id) == ["100"]) }
        }
    }

    @Test("a story present in both feed and search shares its read state across projections")
    func storyInBothFeedAndSearch_sharesReadState() async throws {
        try await withAppCore(
            client: .mock(
                frontPage: { _ in page([storyA, storyB]) },
                search: { _, _ in page([storyA]) }
            ),
            clock: TestClock()
        ) { appCore in
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                await appCore.sendEvent(.toggleRead(id: storyA.id))
                #expect(state.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)
            }

            try await commitSearch("x", on: appCore)

            await appCore.run { appCore in #expect(appCore.state.searchResults.first?.isRead == true) }
        }
    }

    // MARK: Pagination

    @Test("loadMore appends page-1 ids to the snapshot and bumps the cursor")
    func loadMore_appendsAndBumpsCursor() async throws {
        try await withAppCore(
            client: .mock(
                frontPage: { p in
                    if p == 0 { return page([storyA, storyB], totalPages: 3) }
                    if p == 1 { return page([storyC], totalPages: 3) }
                    return page([])
                }
            )
        ) { appCore in
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                #expect(state.feedLoaded?.page == 0)
                #expect(state.feedLoaded?.hasMore == true)
                #expect(state.feedStories.map(\.id) == ["100", "101"])

                await appCore.sendEvent(.loadMore)
                #expect(state.feedLoaded?.page == 1)
                #expect(state.feedLoaded?.hasMore == true)
                #expect(state.feedStories.map(\.id) == ["100", "101", "102"])
            }
        }
    }

    @Test("loadMore on the last page is a no-op")
    func loadMore_onLastPage_isNoop() async throws {
        let calls = CallRecorder()
        try await withAppCore(
            client: .mock(
                frontPage: { p in
                    calls.recordFrontPage(page: p)
                    return page([storyA], totalPages: 1)
                }
            )
        ) { appCore in
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                #expect(state.feedLoaded?.hasMore == false)
                await appCore.sendEvent(.loadMore)
            }
            let pages = calls.frontPageCalls
            #expect(pages == [0])
        }
    }

    @Test("loadMore before any initial fetch is a no-op")
    func loadMore_withoutInitial_isNoop() async throws {
        let calls = CallRecorder()
        try await withAppCore(
            client: .mock(
                frontPage: { p in
                    calls.recordFrontPage(page: p)
                    return page([storyA])
                }
            )
        ) { appCore in
            await appCore.run { await $0.sendEvent(.loadMore) }
            let pages = calls.frontPageCalls
            #expect(pages.isEmpty)
        }
    }

    @Test("refresh during an in-flight loadMore cancels the loadMore")
    func refresh_duringLoadMore_cancelsLoadMore() async throws {
        let calls = CallRecorder()
        let clock = TestClock()
        try await withAppCore(
            client: .mock(
                frontPage: { p in
                    calls.recordFrontPage(page: p)
                    if p == 1 {
                        // Park until the refresh cancels us.
                        try await clock.sleep(for: .seconds(Int.max))
                    }
                    return page([storyA], totalPages: 5)
                }
            ),
            clock: clock
        ) { appCore in
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                #expect(state.feedLoaded?.page == 0)
            }

            let loadMore = Task { [appCore] in
                await appCore.run { await $0.sendEvent(.loadMore) }
            }
            try await appCore.testActor.runPending()
            await appCore.run { appCore in #expect(appCore.state.feedLoadMoreStatus.isLoading == true) }

            // Refresh's `tasks[.feedMore] = nil` cancels the parked page-1 task.
            await appCore.run { await $0.sendEvent(.refresh) }
            await loadMore.value

            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.feedLoaded?.page == 0)
                #expect(state.feedLoadMoreStatus.isLoading == false)
                #expect(state.feedLoadMoreStatus.error == nil)
            }
        }
    }

    @Test("loadMore failure leaves the snapshot and initial status untouched")
    func loadMore_failure_isolatedToLoadMoreStatus() async throws {
        struct Boom: Error {}
        try await withAppCore(
            client: .mock(
                frontPage: { p in
                    if p == 0 { return page([storyA, storyB], totalPages: 5) }
                    throw Boom()
                }
            )
        ) { appCore in
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                let before = state.feedStories.map(\.id)
                await appCore.sendEvent(.loadMore)
                #expect(state.feedStories.map(\.id) == before)
                #expect(state.feedInitialStatus.error == nil)
                #expect(state.feedLoadMoreStatus.error != nil)
            }
        }
    }

    @Test("search paginates symmetrically with feed")
    func search_paginates() async throws {
        try await withAppCore(
            client: .mock(
                search: { _, p in
                    if p == 0 { return page([storyA], totalPages: 2) }
                    if p == 1 { return page([storyB], totalPages: 2) }
                    return page([])
                }
            ),
            clock: TestClock()
        ) { appCore in
            try await commitSearch("x", on: appCore)
            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchResults.map(\.id) == ["100"])
                #expect(state.searchLoaded?.hasMore == true)

                await appCore.sendEvent(.loadMore)
                #expect(state.searchResults.map(\.id) == ["100", "101"])
                #expect(state.searchLoaded?.hasMore == false)
            }
        }
    }

    @Test("clearing search cancels in-flight search load-more")
    func clearSearch_cancelsLoadMore() async throws {
        let clock = TestClock()
        try await withAppCore(
            client: .mock(
                search: { _, p in
                    if p == 0 { return page([storyA], totalPages: 5) }
                    // Park until cancelled.
                    try await clock.sleep(for: .seconds(Int.max))
                    return page([])
                }
            ),
            clock: clock
        ) { appCore in
            try await commitSearch("x", on: appCore)
            await appCore.run { appCore in #expect(appCore.state.searchLoaded?.hasMore == true) }

            let loadMore = Task { [appCore] in
                await appCore.run { await $0.sendEvent(.loadMore) }
            }
            try await appCore.testActor.runPending()
            await appCore.run { appCore in #expect(appCore.state.searchLoadMoreStatus.isLoading == true) }

            await appCore.run { appCore in appCore.state.searchQuery = "" }
            await loadMore.value
            try await appCore.testActor.runPending()

            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchLoaded == nil)
                #expect(state.searchLoadMoreStatus.isLoading == false)
                #expect(state.searchLoadMoreStatus.error == nil)
            }
        }
    }

    @Test("loadMore preserves loadedAt from the initial fetch")
    func loadMore_preservesLoadedAt() async throws {
        // Monotonic `now` so a wrongly-reassigned `loadedAt` would differ deterministically.
        let dates = MonotonicDates()
        try await withAppCore(
            client: .mock(
                frontPage: { p in
                    if p == 0 { return page([storyA], totalPages: 2) }
                    return page([storyB], totalPages: 2)
                }
            ),
            now: dates.next
        ) { appCore in
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                let initialLoadedAt = state.feedLoaded?.loadedAt
                await appCore.sendEvent(.loadMore)
                #expect(state.feedLoaded?.loadedAt == initialLoadedAt)
            }
        }
    }
}
