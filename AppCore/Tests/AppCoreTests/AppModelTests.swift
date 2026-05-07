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

/// Mirrors the producer/consumer watcher pattern that `RootView` and
/// `AndroidBridge` install in production. The body runs concurrently
/// with the watcher; on body exit, the watcher's TaskGroup is cancelled.
///
/// `[model]` capture is load-bearing on each `addTask`: without it,
/// strict concurrency rejects sending a non-Sendable `AppModel` into the
/// sending closure. Explicit capture lets region isolation prove the
/// reference stays in the surrounding MainActor region.

@Suite("AppModel")
struct AppModelTests {

    @Test("refresh populates stories and timestamp")
    func refresh_populatesStoriesAndTimestamp() async {
        let model = AppModel(
            client: HNClient(
                frontPage: { [storyA, storyB] },
                search: { _ in [] }
            )
        )

        #expect(model.state.stories.isEmpty)
        #expect(model.state.lastRefreshedAt == nil)

        await model.dispatch(.refresh)

        #expect(model.state.stories.count == 2)
        #expect(model.state.stories.first?.title == "Top story")
        #expect(model.state.lastRefreshedAt != nil)
        #expect(model.state.isLoading == false)
        #expect(model.state.loadError == nil)
    }

    @Test("refresh records loadError on failure")
    func refresh_recordsErrorOnFailure() async {
        struct Boom: Error {}
        let model = AppModel(
            client: HNClient(
                frontPage: { throw Boom() },
                search: { _ in throw Boom() }
            )
        )

        await model.dispatch(.refresh)

        #expect(model.state.stories.isEmpty)
        #expect(model.state.loadError != nil)
        #expect(model.state.isLoading == false)
    }

    @Test("toggleRead adds and removes")
    func toggleRead_addsAndRemoves() async {
        let model = AppModel(
            client: HNClient(frontPage: { [storyA] }, search: { _ in [] })
        )
        await model.dispatch(.refresh)
        #expect(model.state.stories.first?.isRead == false)

        await model.dispatch(.toggleRead(id: storyA.id))
        #expect(model.state.stories.first?.isRead == true)
        #expect(model.state.readIds.contains(storyA.id))

        await model.dispatch(.toggleRead(id: storyA.id))
        #expect(model.state.stories.first?.isRead == false)
        #expect(model.state.readIds.contains(storyA.id) == false)
    }

    @Test("openStory marks read and emits presentURL command")
    func openStory_marksReadAndEmitsPresentURL() async {
        let model = AppModel(
            client: HNClient(
                frontPage: { [storyA, storyB] },
                search: { _ in [] }
            )
        )
        await model.dispatch(.refresh)

        var iterator = model.commands.makeAsyncIterator()
        await model.dispatch(.openStory(id: storyA.id))

        #expect(model.state.stories.first(where: { $0.id == storyA.id })?.isRead == true)
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("openStory on a story without a URL marks read but emits nothing")
    func openStory_withoutURL_marksReadOnly() async {
        let model = AppModel(
            client: HNClient(
                frontPage: { [storyA, storyB] },
                search: { _ in [] }
            )
        )
        await model.dispatch(.refresh)

        // Open storyA first so we have a known emission to wait on, then
        // open storyB (no URL). The next iteration should yield storyA's
        // command — proving storyB emitted nothing in between.
        var iterator = model.commands.makeAsyncIterator()
        await model.dispatch(.openStory(id: storyB.id))
        await model.dispatch(.openStory(id: storyA.id))

        #expect(model.state.stories.first(where: { $0.id == storyB.id })?.isRead == true)
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("openStory with unknown id is a no-op")
    func openStory_unknownId_isNoop() async {
        let model = AppModel(
            client: HNClient(
                frontPage: { [storyA] },
                search: { _ in [] }
            )
        )
        await model.dispatch(.refresh)
        let readBefore = model.state.readIds

        var iterator = model.commands.makeAsyncIterator()
        await model.dispatch(.openStory(id: "does-not-exist"))
        // Follow with a known-good open so we have something to await.
        await model.dispatch(.openStory(id: storyA.id))

        #expect(model.state.readIds == readBefore.union([storyA.id]))
        let command = await iterator.next()
        #expect(command == .presentURL(value: storyA.url!))
    }

    @Test("read state survives a refresh")
    func toggleRead_survivesRefresh() async {
        let model = AppModel(
            client: HNClient(
                frontPage: { [storyA, storyB] },
                search: { _ in [] }
            )
        )
        // Toggle before any stories are loaded — the kernel still records
        // it; the projection has nothing to map onto yet.
        await model.dispatch(.toggleRead(id: "100"))
        #expect(model.state.readIds.contains("100"))
        #expect(model.state.stories.isEmpty)

        await model.dispatch(.refresh)
        let projected = model.state.stories.first(where: { $0.id == "100" })
        #expect(projected != nil)
        #expect(projected?.isRead == true)
    }

    @Test("ObservedKeyPath emits initial value then yields on each willSet")
    @MainActor
    func observedKeyPath_emitsInitialAndChanges() async {
        let model = AppModel(
            client: HNClient(frontPage: { [] }, search: { _ in [] })
        )

        // Iterate state.observe(\.searchQuery) — first element is the
        // current value (matching `Observations`' initial emission);
        // subsequent elements arrive on each willSet.
        let observer = Task { @MainActor [state = model.state] in
            var captured: [String] = []
            for await q in state.observe(\.searchQuery).prefix(3) {
                captured.append(q)
            }
            return captured
        }
        await Task.megaYield()

        model.state.searchQuery = "ru"
        await Task.megaYield()
        model.state.searchQuery = "rust"

        let captured = await observer.value
        #expect(captured == ["", "ru", "rust"])
    }

    @Test("ObservedKeyPath terminates when surrounding Task is cancelled — even without a subsequent write")
    @MainActor
    func observedKeyPath_terminatesOnCancellationWithoutWrite() async {
        let model = AppModel(
            client: HNClient(frontPage: { [] }, search: { _ in [] })
        )

        // Start an observer that consumes the initial emission then
        // parks awaiting the next willSet.
        let observer = Task { @MainActor [state = model.state] in
            var captured: [String] = []
            for await q in state.observe(\.searchQuery) {
                captured.append(q)
            }
            return captured
        }
        await Task.megaYield()

        // Cancel without writing. The iterator's wait sits on
        // `AsyncStream`'s for-await, which propagates cancellation
        // even when no `willSet` ever fires — so the loop must exit
        // cleanly instead of hanging.
        observer.cancel()

        let captured = await observer.value
        #expect(captured == [""])  // initial-emission only; iterator exited on cancel
    }

    @Test("runFetch debounces and fires search with current query")
    @MainActor
    func runFetch_debouncesAndFires() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let model = AppModel(
            client: HNClient(
                frontPage: { [] },
                search: { query in
                    await calls.recordSearch(query)
                    return [storyA]
                }
            ),
            clock: clock
        )

        // Direct property write (the path @Bindable / per-property JNI
        // setter take); host's watcher would respond by calling runFetch.
        model.state.searchQuery = "rust"
        let fetch = Task { @MainActor [model] in
            await model.runFetch(debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppModel.searchDebounce)
        await fetch.value

        #expect(model.state.searchQuery == "rust")
        #expect(model.state.stories.map(\.id) == ["100"])
        await #expect(calls.searchCalls == ["rust"])
        #expect(model.state.isLoading == false)
    }

    @Test("rapid runFetch calls coalesce — only the latest fires")
    @MainActor
    func runFetch_coalescesRapidKeystrokes() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let model = AppModel(
            client: HNClient(
                frontPage: { [] },
                search: { query in
                    await calls.recordSearch(query)
                    return [storyA]
                }
            ),
            clock: clock
        )

        // Simulate three back-to-back keystrokes the way the production
        // watcher would: write the property, then call runFetch (each
        // call cancels the prior in-flight searchTask).
        model.state.searchQuery = "ru"
        let t1 = Task { @MainActor [model] in
            await model.runFetch(debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()
        model.state.searchQuery = "rus"
        let t2 = Task { @MainActor [model] in
            await model.runFetch(debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()
        model.state.searchQuery = "rust"
        let t3 = Task { @MainActor [model] in
            await model.runFetch(debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()

        await clock.advance(by: AppModel.searchDebounce)
        await t1.value
        await t2.value
        await t3.value

        await #expect(calls.searchCalls == ["rust"])
        #expect(model.state.searchQuery == "rust")
        #expect(model.state.stories.map(\.id) == ["100"])
    }

    @Test("refresh during pending debounce cancels the pending search")
    @MainActor
    func refresh_cancelsPendingDebounce() async {
        let calls = CallRecorder()
        let clock = TestClock()
        let model = AppModel(
            client: HNClient(
                frontPage: {
                    await calls.recordFrontPage()
                    return [storyA, storyB]
                },
                search: { query in
                    await calls.recordSearch(query)
                    return [storyA]
                }
            ),
            clock: clock
        )

        // Pending watcher-style fetch with searchQuery="rust", parked
        // in clock.sleep.
        model.state.searchQuery = "rust"
        let pending = Task { @MainActor [model] in
            await model.runFetch(debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()

        // Refresh's own runFetch cancels the pending task before the
        // debounce elapses.
        await model.dispatch(.refresh)
        await clock.advance(by: AppModel.searchDebounce)
        await pending.value

        // Refresh ran with searchQuery already set to "rust", so it hit
        // the search endpoint. The pending fetch got cancelled before
        // it could fire its own request.
        await #expect(calls.frontPageCalls == 0)
        await #expect(calls.searchCalls == ["rust"])
    }

    @Test("dispatch resumes on caller's actor (SE-0461)")
    @MainActor
    func dispatch_runsOnCallersActor() async {
        let model = AppModel(
            client: HNClient(frontPage: { [] }, search: { _ in [] })
        )
        await model.dispatch(.refresh)
        MainActor.assertIsolated()
    }

    @Test("URLError(.cancelled) from a cancelled fetch is treated as cancellation")
    @MainActor
    func cancelledURLError_doesNotSurfaceAsLoadError() async {
        // URLSession surfaces task cancellation as URLError.cancelled,
        // not Swift's CancellationError. Without the in-Task
        // normalisation, the dispatch arm's generic `catch` would write
        // `loadError = "cancelled"`. Direct contract test.
        let model = AppModel(
            client: HNClient(
                frontPage: { throw URLError(.cancelled) },
                search:    { _ in throw URLError(.cancelled) }
            )
        )

        await model.dispatch(.refresh)

        #expect(model.state.loadError == nil)
        #expect(model.state.hits.isEmpty)
    }

    @Test("cancel-and-replace through URLError(.cancelled) doesn't surface")
    @MainActor
    func cancelAndReplace_throughURLErrorCancelled_silent() async {
        // Reproduces the cold-start race that motivated the URLError
        // normalisation: a slow `.refresh` fetch is in flight when a
        // searchQuery write arrives, the watcher's runFetch
        // cancel-and-replaces the task, and the URLSession-style mock
        // surfaces URLError.cancelled as the task throws. Without the
        // normalisation the prior dispatch's catch arm would have
        // written `loadError = "cancelled"` until the search-query
        // fetch settled.
        let clock = TestClock()
        let model = AppModel(
            client: HNClient(
                frontPage: {
                    // Park until the calling Task is cancelled, then
                    // throw URLError(.cancelled) like URLSession does.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    throw URLError(.cancelled)
                },
                search: { _ in [storyA] }
            ),
            clock: clock
        )

        // Start a slow refresh that parks at frontPage (waiting to be
        // cancelled), then simulate a watcher-driven setSearchQuery by
        // writing the property and calling runFetch.
        let refreshTask = Task { @MainActor [model] in await model.dispatch(.refresh) }
        await Task.megaYield()

        model.state.searchQuery = "rust"
        let queryTask = Task { @MainActor [model] in
            await model.runFetch(debounce: AppModel.searchDebounce)
        }
        await Task.megaYield()
        await clock.advance(by: AppModel.searchDebounce)

        await refreshTask.value
        await queryTask.value

        #expect(model.state.loadError == nil)
        #expect(model.state.searchQuery == "rust")
        #expect(model.state.stories.map(\.id) == ["100"])
    }
}
