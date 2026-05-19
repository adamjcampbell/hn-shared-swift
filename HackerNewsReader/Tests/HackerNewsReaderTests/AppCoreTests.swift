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
/// instead when asserting mid-flight.
private func commitSearch(_ query: String, on appCore: AppCore, clock: TestClock<Duration>) async {
    await appCore.testActor.settle()
    await appCore.run { core in core.state.searchQuery = query }
    await appCore.testActor.settle()
    await clock.advance(by: AppCore.searchDebounce)
    await appCore.testActor.settle()
}

@Suite("AppCore")
struct AppCoreTests {

    @Test("refresh populates feed stories and timestamp")
    func refresh_populatesStoriesAndTimestamp() async {
        await withAppCore(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { _, _, appCore in
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
    func refresh_recordsErrorOnFailure() async {
        struct Boom: Error {}
        await withAppCore(
            client: .mock(
                frontPage: { _ in throw Boom() },
                search: { _, _ in throw Boom() }
            )
        ) { _, _, appCore in
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                #expect(state.feedStories.isEmpty)
                #expect(state.feedInitialStatus.error != nil)
            }
        }
    }

    @Test("toggleRead adds and removes")
    func toggleRead_addsAndRemoves() async {
        await withAppCore(
            client: .mock(frontPage: { _ in page([storyA]) })
        ) { _, _, appCore in
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
    func openStory_marksReadAndEmitsPresentURL() async {
        await withAppCore(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { _, commands, appCore in
            await appCore.run { await $0.sendEvent(.refresh) }

            var iterator = commands.makeAsyncIterator()
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
    func openStory_withoutURL_marksReadOnly() async {
        await withAppCore(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { _, commands, appCore in
            await appCore.run { await $0.sendEvent(.refresh) }

            // First emission we observe is storyA's — proving storyB emitted nothing.
            var iterator = commands.makeAsyncIterator()
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
    func openStory_unknownId_isNoop() async {
        await withAppCore(
            client: .mock(frontPage: { _ in page([storyA]) })
        ) { _, commands, appCore in
            var iterator = commands.makeAsyncIterator()
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
    func toggleRead_survivesRefresh() async {
        await withAppCore(
            client: .mock(frontPage: { _ in page([storyA, storyB]) })
        ) { _, _, appCore in
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
    func listener_debouncesAndFires() async {
        let calls = CallRecorder()
        let clock = TestClock()
        await withAppCore(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            clock: clock
        ) { _, _, appCore in
            await commitSearch("rust", on: appCore, clock: clock)

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
    func isSearchLoading_activatesOnFirstKeystroke() async {
        let clock = TestClock()
        await withAppCore(
            client: .mock(search: { _, _ in page([storyA]) }),
            clock: clock
        ) { _, _, appCore in
            await appCore.testActor.settle()
            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchInitialStatus.isLoading == false)
                state.searchQuery = "r"
            }
            await appCore.testActor.settle()

            // Spinner is on before the debounce elapses.
            await appCore.run { appCore in #expect(appCore.state.searchInitialStatus.isLoading == true) }

            await clock.advance(by: AppCore.searchDebounce)
            await appCore.testActor.settle()

            await appCore.run { appCore in #expect(appCore.state.searchInitialStatus.isLoading == false) }
        }
    }

    @Test("URLError(.cancelled) from a cancelled feed fetch is treated as cancellation")
    func cancelledURLError_doesNotSurfaceAsFeedLoadError() async {
        // URLSession surfaces task cancellation as URLError.cancelled, not CancellationError.
        await withAppCore(
            client: .mock(
                frontPage: { _ in throw URLError(.cancelled) },
                search:    { _, _ in throw URLError(.cancelled) }
            )
        ) { _, _, appCore in
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                #expect(state.feedInitialStatus.error == nil)
                #expect(state.feedLoaded == nil)
            }
        }
    }

    @Test("search-to-search cancel-and-replace through URLError(.cancelled) doesn't surface")
    func searchCancelAndReplace_throughURLErrorCancelled_silent() async {
        let clock = TestClock()
        await withAppCore(
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
        ) { _, _, appCore in
            await appCore.testActor.settle()
            await appCore.run { appCore in appCore.state.searchQuery = "ru" }
            await appCore.testActor.settle()
            await clock.advance(by: AppCore.searchDebounce)
            await appCore.testActor.settle()

            await appCore.run { appCore in appCore.state.searchQuery = "rust" }
            await appCore.testActor.settle()
            await clock.advance(by: AppCore.searchDebounce)
            await appCore.testActor.settle()

            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchInitialStatus.error == nil)
                #expect(state.searchQuery == "rust")
                #expect(state.searchResults.map(\.id) == ["100"])
            }
        }
    }

    @Test("clearing the search query cancels the search, clears results, and does not refetch the feed")
    func clearingSearchQuery_cancelsAndClearsResults() async {
        let calls = CallRecorder()
        let clock = TestClock()
        await withAppCore(
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
        ) { _, _, appCore in
            let feedBefore = await appCore.run { appCore in
                await appCore.sendEvent(.refresh)
                return appCore.state.feedStories.map(\.id)
            }
            let frontPageBefore = calls.frontPageCalls.count

            await commitSearch("rust", on: appCore, clock: clock)
            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchResults.map(\.id) == ["100"])
                state.searchQuery = ""
            }
            await appCore.testActor.settle()

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
    func feedSurvivesActiveSearch() async {
        let clock = TestClock()
        await withAppCore(
            client: .mock(
                frontPage: { _ in page([storyA, storyB]) },
                search: { _, _ in page([storyA]) }
            ),
            clock: clock
        ) { _, _, appCore in
            let feedSnapshot = await appCore.run { appCore in
                await appCore.sendEvent(.refresh)
                return appCore.state.feedStories.map(\.id)
            }
            #expect(feedSnapshot == ["100", "101"])

            await commitSearch("x", on: appCore, clock: clock)

            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchResults.map(\.id) == ["100"])
                #expect(state.feedStories.map(\.id) == feedSnapshot)
            }
        }
    }

    @Test("backspacing all the way to empty during an in-flight fetch still clears results")
    func listener_burstWriteDuringFetchClearsResults() async {
        let calls = CallRecorder()
        let clock = TestClock()
        await withAppCore(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            clock: clock
        ) { _, _, appCore in
            // Let the listener reach its `for await` suspension before the first write.
            await appCore.testActor.settle()

            await appCore.run { appCore in appCore.state.searchQuery = "rust" }
            await appCore.testActor.settle()

            await appCore.run { appCore in appCore.state.searchQuery = "" }
            await appCore.testActor.settle()

            await clock.advance(by: AppCore.searchDebounce)
            await appCore.testActor.settle()

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
    func listener_rapidKeystrokes_onlyFinalQueryFires() async {
        let calls = CallRecorder()
        let clock = TestClock()
        await withAppCore(
            client: .mock(
                search: { query, p in
                    calls.recordSearch(query, page: p)
                    return page([storyA])
                }
            ),
            clock: clock
        ) { _, _, appCore in
            // Let the listener reach its `for await` suspension before the first write.
            await appCore.testActor.settle()

            await appCore.run { appCore in appCore.state.searchQuery = "r" }
            await appCore.testActor.settle()
            await appCore.run { appCore in appCore.state.searchQuery = "ru" }
            await appCore.testActor.settle()
            await appCore.run { appCore in appCore.state.searchQuery = "rust" }
            await appCore.testActor.settle()

            await clock.advance(by: AppCore.searchDebounce)
            await appCore.testActor.settle()

            let recorded = calls.searchCalls
            #expect(recorded.map(\.0) == ["rust"])
            await appCore.run { appCore in #expect(appCore.state.searchResults.map(\.id) == ["100"]) }
        }
    }

    @Test("a story present in both feed and search shares its read state across projections")
    func storyInBothFeedAndSearch_sharesReadState() async {
        let clock = TestClock()
        await withAppCore(
            client: .mock(
                frontPage: { _ in page([storyA, storyB]) },
                search: { _, _ in page([storyA]) }
            ),
            clock: clock
        ) { _, _, appCore in
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                await appCore.sendEvent(.toggleRead(id: storyA.id))
                #expect(state.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)
            }

            await commitSearch("x", on: appCore, clock: clock)

            await appCore.run { appCore in #expect(appCore.state.searchResults.first?.isRead == true) }
        }
    }

    // MARK: Pagination

    @Test("loadMore appends page-1 ids to the snapshot and bumps the cursor")
    func loadMore_appendsAndBumpsCursor() async {
        await withAppCore(
            client: .mock(
                frontPage: { p in
                    if p == 0 { return page([storyA, storyB], totalPages: 3) }
                    if p == 1 { return page([storyC], totalPages: 3) }
                    return page([])
                }
            )
        ) { _, _, appCore in
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
    func loadMore_onLastPage_isNoop() async {
        let calls = CallRecorder()
        await withAppCore(
            client: .mock(
                frontPage: { p in
                    calls.recordFrontPage(page: p)
                    return page([storyA], totalPages: 1)
                }
            )
        ) { _, _, appCore in
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
    func loadMore_withoutInitial_isNoop() async {
        let calls = CallRecorder()
        await withAppCore(
            client: .mock(
                frontPage: { p in
                    calls.recordFrontPage(page: p)
                    return page([storyA])
                }
            )
        ) { _, _, appCore in
            await appCore.run { await $0.sendEvent(.loadMore) }
            let pages = calls.frontPageCalls
            #expect(pages.isEmpty)
        }
    }

    @Test("refresh during an in-flight loadMore cancels the loadMore")
    func refresh_duringLoadMore_cancelsLoadMore() async {
        let calls = CallRecorder()
        let clock = TestClock()
        await withAppCore(
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
        ) { _, _, appCore in
            await appCore.run { appCore in
                let state = appCore.state
                await appCore.sendEvent(.refresh)
                #expect(state.feedLoaded?.page == 0)
            }

            let loadMore = Task { [appCore] in
                await appCore.run { await $0.sendEvent(.loadMore) }
            }
            await appCore.testActor.settle()
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
    func loadMore_failure_isolatedToLoadMoreStatus() async {
        struct Boom: Error {}
        await withAppCore(
            client: .mock(
                frontPage: { p in
                    if p == 0 { return page([storyA, storyB], totalPages: 5) }
                    throw Boom()
                }
            )
        ) { _, _, appCore in
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
    func search_paginates() async {
        let clock = TestClock()
        await withAppCore(
            client: .mock(
                search: { _, p in
                    if p == 0 { return page([storyA], totalPages: 2) }
                    if p == 1 { return page([storyB], totalPages: 2) }
                    return page([])
                }
            ),
            clock: clock
        ) { _, _, appCore in
            await commitSearch("x", on: appCore, clock: clock)
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
    func clearSearch_cancelsLoadMore() async {
        let clock = TestClock()
        await withAppCore(
            client: .mock(
                search: { _, p in
                    if p == 0 { return page([storyA], totalPages: 5) }
                    // Park until cancelled.
                    try await clock.sleep(for: .seconds(Int.max))
                    return page([])
                }
            ),
            clock: clock
        ) { _, _, appCore in
            await commitSearch("x", on: appCore, clock: clock)
            await appCore.run { appCore in #expect(appCore.state.searchLoaded?.hasMore == true) }

            let loadMore = Task { [appCore] in
                await appCore.run { await $0.sendEvent(.loadMore) }
            }
            await appCore.testActor.settle()
            await appCore.run { appCore in #expect(appCore.state.searchLoadMoreStatus.isLoading == true) }

            await appCore.run { appCore in appCore.state.searchQuery = "" }
            await loadMore.value
            await appCore.testActor.settle()

            await appCore.run { appCore in
                let state = appCore.state
                #expect(state.searchLoaded == nil)
                #expect(state.searchLoadMoreStatus.isLoading == false)
                #expect(state.searchLoadMoreStatus.error == nil)
            }
        }
    }

    @Test("loadMore preserves loadedAt from the initial fetch")
    func loadMore_preservesLoadedAt() async {
        // Monotonic `now` so a wrongly-reassigned `loadedAt` would differ deterministically.
        let dates = MonotonicDates()
        await withAppCore(
            client: .mock(
                frontPage: { p in
                    if p == 0 { return page([storyA], totalPages: 2) }
                    return page([storyB], totalPages: 2)
                }
            ),
            now: dates.next
        ) { _, _, appCore in
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
