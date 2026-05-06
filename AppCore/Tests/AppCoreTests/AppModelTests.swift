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

    @Test("setSearchQuery debounces, then fires one request")
    @MainActor
    func setSearchQuery_firesDebouncedRequest() async {
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

        let dispatch = Task { @MainActor in
            await model.dispatch(.setSearchQuery(value: "rust"))
        }
        // Yield until the dispatch is parked in `clock.sleep`.
        await Task.megaYield()
        await clock.advance(by: AppModel.searchDebounce)
        await dispatch.value

        #expect(model.state.searchQuery == "rust")
        #expect(model.state.stories.map(\.id) == ["100"])
        await #expect(calls.searchCalls == ["rust"])
        #expect(model.state.isLoading == false)
    }

    @Test("rapid keystrokes coalesce — only the latest fires")
    @MainActor
    func setSearchQuery_coalescesRapidKeystrokes() async {
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

        // Fire three concurrent dispatches on MainActor. Each one
        // synchronously cancels the prior `searchTask` and parks in
        // `clock.sleep`.
        let t1 = Task { @MainActor in await model.dispatch(.setSearchQuery(value: "ru")) }
        let t2 = Task { @MainActor in await model.dispatch(.setSearchQuery(value: "rus")) }
        let t3 = Task { @MainActor in await model.dispatch(.setSearchQuery(value: "rust")) }
        await Task.megaYield()

        // Advance the virtual clock past the debounce. The cancelled
        // sleeps return CancellationError; only the latest survives to
        // call `client.search`.
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

        // Start a pending search whose debounce is in flight, then fire
        // refresh. Refresh's own `runFetch` cancels the pending task.
        let pending = Task { @MainActor in
            await model.dispatch(.setSearchQuery(value: "rust"))
        }
        await Task.megaYield()
        await model.dispatch(.refresh)
        // Drain the pending dispatch (its sleep was cancelled, so it
        // resolves to .cancelled and returns).
        await clock.advance(by: AppModel.searchDebounce)
        await pending.value

        // Refresh ran with searchQuery already set to "rust", so it hit
        // the search endpoint. The pending dispatch's debounce got
        // cancelled before it could fire its own request.
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
}

@Suite("AppEvent JSON round-trip")
struct AppEventTests {

    @Test("toggleRead encodes with discriminator and id payload")
    func toggleRead_wireShape() throws {
        let event = AppEvent.toggleRead(id: "39184235")
        let json = event.toJSON()
        #expect(json.contains("\"type\":\"toggleRead\""))
        #expect(json.contains("\"id\":\"39184235\""))

        let decoded = try #require(AppEvent(json: json))
        #expect(decoded == event)
    }

    @Test("openStory encodes with discriminator and id payload")
    func openStory_wireShape() throws {
        let event = AppEvent.openStory(id: "39184235")
        let json = event.toJSON()
        #expect(json.contains("\"type\":\"openStory\""))
        #expect(json.contains("\"id\":\"39184235\""))

        let decoded = try #require(AppEvent(json: json))
        #expect(decoded == event)
    }

    @Test("refresh encodes as bare type discriminator")
    func refresh_wireShape() throws {
        let event = AppEvent.refresh
        let json = event.toJSON()
        #expect(json.contains("\"type\":\"refresh\""))

        let decoded = try #require(AppEvent(json: json))
        #expect(decoded == event)
    }

    @Test("setSearchQuery encodes with value payload")
    func setSearchQuery_wireShape() throws {
        let event = AppEvent.setSearchQuery(value: "rust")
        let json = event.toJSON()
        #expect(json.contains("\"type\":\"setSearchQuery\""))
        #expect(json.contains("\"value\":\"rust\""))

        let decoded = try #require(AppEvent(json: json))
        #expect(decoded == event)
    }

    @Test("decodes hand-written wire literals")
    func decodes_handWrittenLiterals() throws {
        // These are the literal payloads the Kotlin side sends; if Swift
        // ever stops accepting them the cross-language contract has drifted.
        let toggle = try #require(AppEvent(json: #"{"type":"toggleRead","id":"100"}"#))
        #expect(toggle == .toggleRead(id: "100"))

        let open = try #require(AppEvent(json: #"{"type":"openStory","id":"100"}"#))
        #expect(open == .openStory(id: "100"))

        let refresh = try #require(AppEvent(json: #"{"type":"refresh"}"#))
        #expect(refresh == .refresh)

        let query = try #require(AppEvent(json: #"{"type":"setSearchQuery","value":"rust"}"#))
        #expect(query == .setSearchQuery(value: "rust"))
    }

    @Test("rejects unknown discriminators")
    func rejects_unknownDiscriminator() {
        #expect(AppEvent(json: #"{"type":"unknown"}"#) == nil)
        #expect(AppEvent(json: #"{}"#) == nil)
        #expect(AppEvent(json: "garbage") == nil)
    }
}

@Suite("AppCommand JSON round-trip")
struct AppCommandTests {

    @Test("presentURL encodes with discriminator and value payload")
    func presentURL_wireShape() throws {
        let command = AppCommand.presentURL(value: "https://example.com/a")
        let json = command.toJSON()
        #expect(json.contains("\"type\":\"presentURL\""))
        #expect(json.contains("\"value\":\"https:\\/\\/example.com\\/a\""))

        let decoded = try #require(AppCommand(json: json))
        #expect(decoded == command)
    }

    @Test("decodes hand-written wire literals")
    func decodes_handWrittenLiterals() throws {
        // The literal payload Kotlin's kotlinx-serialization will receive
        // through the JNI CommandSink. If Swift ever stops accepting it,
        // the cross-language contract has drifted.
        let present = try #require(AppCommand(json: #"{"type":"presentURL","value":"https://example.com"}"#))
        #expect(present == .presentURL(value: "https://example.com"))
    }

    @Test("rejects unknown discriminators")
    func rejects_unknownDiscriminator() {
        #expect(AppCommand(json: #"{"type":"unknown"}"#) == nil)
        #expect(AppCommand(json: #"{}"#) == nil)
        #expect(AppCommand(json: "garbage") == nil)
    }
}

@Suite("AppState JSON wire shape")
struct AppStateWireTests {

    @Test("snapshot omits internal storage and embeds isRead on each story")
    func snapshot_omitsInternalStorage_andEmbedsIsReadOnStory() async {
        let model = AppModel(
            client: HNClient(
                frontPage: {
                    [
                        HNHit(id: "100", title: "A", author: "x", points: 1, commentCount: 0, url: nil, createdAt: Date(timeIntervalSince1970: 1)),
                        HNHit(id: "101", title: "B", author: "y", points: 2, commentCount: 0, url: nil, createdAt: Date(timeIntervalSince1970: 2)),
                    ]
                },
                search: { _ in [] }
            )
        )
        await model.dispatch(.refresh)
        await model.dispatch(.toggleRead(id: "100"))

        let json = model.state.toJSON()

        // Internal storage never crosses the wire.
        #expect(!json.contains("\"hits\""))
        #expect(!json.contains("\"readIds\""))
        // The merged stories list is what Android sees.
        #expect(json.contains("\"stories\""))
        #expect(json.contains("\"isRead\":true"))
        #expect(json.contains("\"isRead\":false"))
    }
}
