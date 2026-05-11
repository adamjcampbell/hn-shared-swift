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

/// Records the queries the mock client was called with. An actor so the
/// `@Sendable` closures in the mock can mutate it from the Task's
/// executor while the test reads it from MainActor.
private actor CallRecorder {
    private(set) var frontPageCalls = 0
    private(set) var searchCalls: [String] = []

    func recordFrontPage() { frontPageCalls += 1 }
    func recordSearch(_ query: String) { searchCalls.append(query) }
}

/// Test fixture for `AppModel` with optional `HNClient` mocks and an
/// injected clock. Defaults give an empty front page and an empty
/// search — override the relevant closure to express the test's intent.
private func makeModel(
    frontPage: @escaping @Sendable () async throws -> [HNHit] = { [] },
    search: @escaping @Sendable (String) async throws -> [HNHit] = { _ in [] },
    clock: any Clock<Duration> = ContinuousClock()
) -> AppModel {
    AppModel(
        client: HNClient(frontPage: frontPage, search: search),
        clock: clock
    )
}

@Suite("AppModel")
struct AppModelTests {

    @Test("refresh populates feed stories and timestamp")
    func refresh_populatesStoriesAndTimestamp() async {
        let model = makeModel(frontPage: { [storyA, storyB] })

        #expect(model.state.feedStories.isEmpty)
        #expect(model.state.lastRefreshedAt == nil)

        await model.dispatch(.refresh)

        #expect(model.state.feedStories.count == 2)
        #expect(model.state.feedStories.first?.title == "Top story")
        #expect(model.state.lastRefreshedAt != nil)
        #expect(model.state.feedLoadError == nil)
    }

    @Test("refresh records feedLoadError on failure")
    func refresh_recordsErrorOnFailure() async {
        struct Boom: Error {}
        let model = makeModel(
            frontPage: { throw Boom() },
            search: { _ in throw Boom() }
        )

        await model.dispatch(.refresh)

        #expect(model.state.feedStories.isEmpty)
        #expect(model.state.feedLoadError != nil)
    }

    @Test("toggleRead adds and removes")
    func toggleRead_addsAndRemoves() async {
        let model = makeModel(frontPage: { [storyA] })
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
        let model = makeModel(frontPage: { [storyA, storyB] })
        await model.dispatch(.refresh)

        var iterator = model.commands.makeAsyncIterator()
        await model.dispatch(.openStory(id: storyA.id))

        #expect(model.state.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("openStory on a story without a URL marks read but emits nothing")
    func openStory_withoutURL_marksReadOnly() async {
        let model = makeModel(frontPage: { [storyA, storyB] })
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
        let model = makeModel(frontPage: { [storyA] })
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
        let model = makeModel(frontPage: { [storyA, storyB] })
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
            search: { query in
                await calls.recordSearch(query)
                return [storyA]
            },
            clock: clock
        )

        model.state.searchQuery = "rust"
        let fetch = Task { @MainActor [model] in
            await model.runSearchFetch(query: "rust", debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppModel.searchDebounce)
        await fetch.value

        #expect(model.state.searchQuery == "rust")
        #expect(model.state.searchResults.map(\.id) == ["100"])
        await #expect(calls.searchCalls == ["rust"])
    }

    @Test("isSearchLoading activates on first keystroke, before debounce elapses")
    @MainActor
    func isSearchLoading_activatesOnFirstKeystroke() async {
        let clock = TestClock()
        let model = makeModel(search: { _ in [storyA] }, clock: clock)

        #expect(model.state.isSearchLoading == false)

        let fetch = Task { @MainActor [model] in
            await model.runSearchFetch(query: "r", debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()

        // Spinner asserted synchronously on entry, before the debounce.
        #expect(model.state.isSearchLoading == true)

        await clock.advance(by: AppModel.searchDebounce)
        await fetch.value

        #expect(model.state.isSearchLoading == false)
    }

    @Test("rapid runSearchFetch calls coalesce — only the latest fires")
    @MainActor
    func runSearchFetch_coalescesRapidKeystrokes() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let model = makeModel(
            search: { query in
                await calls.recordSearch(query)
                return [storyA]
            },
            clock: clock
        )

        // Three back-to-back keystrokes; each runSearchFetch cancels the
        // prior in-flight searchTask, so only the latest query fires.
        model.state.searchQuery = "ru"
        let t1 = Task { @MainActor [model] in
            await model.runSearchFetch(query: "ru", debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()
        model.state.searchQuery = "rus"
        let t2 = Task { @MainActor [model] in
            await model.runSearchFetch(query: "rus", debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()
        model.state.searchQuery = "rust"
        let t3 = Task { @MainActor [model] in
            await model.runSearchFetch(query: "rust", debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()

        await clock.advance(by: AppModel.searchDebounce)
        await t1.value
        await t2.value
        await t3.value

        await #expect(calls.searchCalls == ["rust"])
        #expect(model.state.searchQuery == "rust")
        #expect(model.state.searchResults.map(\.id) == ["100"])
    }

    @Test("refresh while a search is in flight re-runs the current search, not the feed")
    @MainActor
    func refresh_whileSearching_reRunsSearch() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let model = makeModel(
            frontPage: {
                await calls.recordFrontPage()
                return [storyA, storyB]
            },
            search: { query in
                await calls.recordSearch(query)
                return [storyA]
            },
            clock: clock
        )

        model.state.searchQuery = "rust"
        let pending = Task { @MainActor [model] in
            await model.runSearchFetch(query: "rust", debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()

        // .refresh with non-empty searchQuery re-runs the search; the
        // pending fetch is cancelled before it issues its own request.
        await model.dispatch(.refresh)
        await clock.advance(by: AppModel.searchDebounce)
        await pending.value

        await #expect(calls.frontPageCalls == 0)
        await #expect(calls.searchCalls == ["rust"])
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
        // `feedLoadError = "cancelled"`.
        let model = makeModel(
            frontPage: { throw URLError(.cancelled) },
            search:    { _ in throw URLError(.cancelled) }
        )

        await model.dispatch(.refresh)

        #expect(model.state.feedLoadError == nil)
        #expect(model.state.feedIds.isEmpty)
    }

    @Test("search-to-search cancel-and-replace through URLError(.cancelled) doesn't surface")
    @MainActor
    func searchCancelAndReplace_throughURLErrorCancelled_silent() async {
        // Without the URLError → CancellationError normalisation, the
        // prior dispatch's catch arm would write `searchLoadError =
        // "cancelled"` until the new fetch settled.
        let clock = TestClock()
        let model = makeModel(
            search: { query in
                if query == "ru" {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    throw URLError(.cancelled)
                }
                return [storyA]
            },
            clock: clock
        )

        model.state.searchQuery = "ru"
        let firstSearch = Task { @MainActor [model] in
            await model.runSearchFetch(query: "ru", debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppModel.searchDebounce)
        await Task.megaYield()

        model.state.searchQuery = "rust"
        let secondSearch = Task { @MainActor [model] in
            await model.runSearchFetch(query: "rust", debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppModel.searchDebounce)

        await firstSearch.value
        await secondSearch.value

        #expect(model.state.searchLoadError == nil)
        #expect(model.state.searchQuery == "rust")
        #expect(model.state.searchResults.map(\.id) == ["100"])
    }

    @Test("clearing the search query cancels the search, clears results, and does not refetch the feed")
    @MainActor
    func clearingSearchQuery_cancelsAndClearsResults() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let model = makeModel(
            frontPage: {
                await calls.recordFrontPage()
                return [storyA, storyB]
            },
            search: { query in
                await calls.recordSearch(query)
                return [storyA]
            },
            clock: clock
        )

        await model.dispatch(.refresh)
        let feedBefore = model.state.feedStories.map(\.id)
        let frontPageBefore = await calls.frontPageCalls

        model.state.searchQuery = "rust"
        let search = Task { @MainActor [model] in
            await model.runSearchFetch(query: "rust", debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppModel.searchDebounce)
        await search.value
        #expect(model.state.searchResults.map(\.id) == ["100"])

        model.state.searchQuery = ""
        model.clearSearch()

        #expect(model.state.searchResults.isEmpty)
        #expect(model.state.searchLoadError == nil)
        #expect(model.state.isSearchLoading == false)
        #expect(model.state.feedStories.map(\.id) == feedBefore)
        await #expect(calls.frontPageCalls == frontPageBefore)
        await #expect(calls.searchCalls == ["rust"])
    }

    @Test("feed survives an active search")
    @MainActor
    func feedSurvivesActiveSearch() async {
        let clock = TestClock()
        let model = makeModel(
            frontPage: { [storyA, storyB] },
            search: { _ in [storyA] },
            clock: clock
        )

        await model.dispatch(.refresh)
        let feedSnapshot = model.state.feedStories.map(\.id)
        #expect(feedSnapshot == ["100", "101"])

        model.state.searchQuery = "x"
        let search = Task { @MainActor [model] in
            await model.runSearchFetch(query: "x", debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppModel.searchDebounce)
        await search.value

        #expect(model.state.searchResults.map(\.id) == ["100"])
        #expect(model.state.feedStories.map(\.id) == feedSnapshot)
    }

    @Test("backspacing all the way to empty during an in-flight fetch still clears results")
    @MainActor
    func runSearchQueryWatcher_burstWriteDuringFetchClearsResults() async {
        // Regression: burst writes during an in-flight fetch must still
        // clear results when the final value is empty. `searchQueryChanges`
        // is `.bufferingNewest(1)`, so the empty write at the end of the
        // burst is what the next watcher iteration consumes.
        let calls = CallRecorder()
        let clock = TestClock()
        let model = makeModel(
            search: { query in
                await calls.recordSearch(query)
                return [storyA]
            },
            clock: clock
        )

        let watcher = Task { @MainActor [model] in
            await model.runSearchQueryWatcher()
        }
        await Task.megaYield()

        // Watcher reads "rust" and parks in `runSearchFetch`'s debounce.
        model.state.searchQuery = "rust"
        await Task.megaYield()

        // Backspace to empty during the in-flight fetch.
        model.state.searchQuery = ""
        await Task.megaYield()

        await clock.advance(by: AppModel.searchDebounce)
        await Task.megaYield()

        #expect(model.state.searchResults.isEmpty)
        #expect(model.state.searchLoadError == nil)
        #expect(model.state.isSearchLoading == false)
        await #expect(calls.searchCalls == ["rust"])

        watcher.cancel()
        _ = await watcher.value
    }

    @Test("a story present in both feed and search shares its read state across projections")
    @MainActor
    func storyInBothFeedAndSearch_sharesReadState() async {
        let clock = TestClock()
        let model = makeModel(
            frontPage: { [storyA, storyB] },
            search: { _ in [storyA] },
            clock: clock
        )

        await model.dispatch(.refresh)
        await model.dispatch(.toggleRead(id: storyA.id))
        #expect(model.state.feedStories.first(where: { $0.id == storyA.id })?.isRead == true)

        model.state.searchQuery = "x"
        let search = Task { @MainActor [model] in
            await model.runSearchFetch(query: "x", debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppModel.searchDebounce)
        await search.value

        #expect(model.state.searchResults.first?.isRead == true)
    }

}
