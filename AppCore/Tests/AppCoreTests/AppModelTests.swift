import Foundation
import Testing
@testable import AppCore

private let twoStoriesFixture: String = #"""
{
  "hits": [
    {
      "objectID": "100",
      "title": "Top story",
      "author": "alice",
      "points": 50,
      "num_comments": 10,
      "url": "https://example.com/a",
      "created_at": "2026-05-04T08:00:00.000Z"
    },
    {
      "objectID": "101",
      "title": "Second story",
      "author": "bob",
      "points": 20,
      "num_comments": 3,
      "url": null,
      "created_at": "2026-05-04T08:01:00.000Z"
    }
  ]
}
"""#

@Suite("AppModel", .serialized)
struct AppModelTests {

    init() { URLProtocolStub.reset() }

    @Test("refresh populates stories and timestamp")
    func refresh_populatesStoriesAndTimestamp() async {
        URLProtocolStub.responder = { request in
            okResponse(twoStoriesFixture, for: request.url!)
        }

        let model = AppModel(client: HNClient(session: makeStubbedSession()))
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
        // Responder unset → URLProtocolStub fails the request.
        let model = AppModel(client: HNClient(session: makeStubbedSession()))

        await model.dispatch(.refresh)

        #expect(model.state.stories.isEmpty)
        #expect(model.state.loadError != nil)
        #expect(model.state.isLoading == false)
    }

    @Test("toggleRead adds and removes")
    func toggleRead_addsAndRemoves() async {
        let model = AppModel()
        #expect(model.state.read.contains("100") == false)

        await model.dispatch(.toggleRead(id: "100"))
        #expect(model.state.read.contains("100"))

        await model.dispatch(.toggleRead(id: "100"))
        #expect(model.state.read.contains("100") == false)
    }

    @Test("read state survives a refresh")
    func toggleRead_survivesRefresh() async {
        URLProtocolStub.responder = { request in
            okResponse(twoStoriesFixture, for: request.url!)
        }

        let model = AppModel(client: HNClient(session: makeStubbedSession()))
        await model.dispatch(.toggleRead(id: "100"))
        #expect(model.state.read.contains("100"))

        await model.dispatch(.refresh)
        // The id is back in the freshly fetched list, AND still in read.
        #expect(model.state.stories.contains(where: { $0.id == "100" }))
        #expect(model.state.read.contains("100"))
    }

    @Test("setSearchQuery updates state without firing a fetch")
    func setSearchQuery_localOnly() async {
        var requestCount = 0
        URLProtocolStub.requestRecorder = { _ in requestCount += 1 }

        let model = AppModel(client: HNClient(session: makeStubbedSession()))
        await model.dispatch(.setSearchQuery(value: "rust"))

        #expect(model.state.searchQuery == "rust")
        // No request fired — debouncing + fetch is the platform UI's job
        // (`task(id:)` on iOS, `LaunchedEffect` on Android), which calls
        // `.refresh` after the debounce.
        #expect(requestCount == 0)
        #expect(model.state.isLoading == false)
    }

    @Test("refresh uses search endpoint when searchQuery is non-empty")
    func refresh_searchPath() async throws {
        var lastURL: URL?
        URLProtocolStub.responder = { request in
            lastURL = request.url
            return okResponse(twoStoriesFixture, for: request.url!)
        }

        let model = AppModel(client: HNClient(session: makeStubbedSession()))
        await model.dispatch(.setSearchQuery(value: "rust"))
        await model.dispatch(.refresh)

        let url = try #require(lastURL)
        #expect(url.path == "/api/v1/search")
        #expect(url.absoluteString.contains("query=rust"))
    }

    @Test("dispatch resumes on caller's actor (SE-0461)")
    @MainActor
    func dispatch_runsOnCallersActor() async {
        URLProtocolStub.responder = { request in
            okResponse(twoStoriesFixture, for: request.url!)
        }

        let model = AppModel(client: HNClient(session: makeStubbedSession()))
        await model.dispatch(.refresh)
        // SE-0461: NonisolatedNonsendingByDefault means dispatch runs on
        // the caller's actor (MainActor here) and the resumption after
        // the await stays on it.
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
