import Foundation
import Testing
@testable import HackerNews

@Suite("Client.frontPage (Firebase)")
struct FirebaseFrontPageTests {

    @Test("hits topstories.json then per-item URLs")
    func hitsTopstoriesAndItems() async throws {
        let captured = CapturedURLs()
        let client = Client(fetch: firebaseMock(
            topstories: [1, 2],
            items: [
                1: itemJSON(id: 1, title: "First"),
                2: itemJSON(id: 2, title: "Second"),
            ],
            recordURL: { url in await captured.record(url) }
        ))

        _ = try await client.frontPage(0)

        let urls = await captured.urls
        let paths = urls.map(\.path).sorted()
        #expect(paths == ["/v0/item/1.json", "/v0/item/2.json", "/v0/topstories.json"])
    }

    @Test("preserves topstories order regardless of item completion order")
    func preservesOrder() async throws {
        // Items returned in reverse; the sort+index logic is what's under test.
        let client = Client(fetch: firebaseMock(
            topstories: [10, 20, 30],
            items: [
                10: itemJSON(id: 10, title: "Ten"),
                20: itemJSON(id: 20, title: "Twenty"),
                30: itemJSON(id: 30, title: "Thirty"),
            ],
            recordURL: { _ in }
        ))

        let page = try await client.frontPage(0)

        #expect(page.stories.map(\.id) == ["10", "20", "30"])
        #expect(page.stories.map(\.title) == ["Ten", "Twenty", "Thirty"])
    }

    @Test("page 1 fetches items 50-99")
    func pageOneFetchesCorrectSlice() async throws {
        let captured = CapturedURLs()
        let ids = Array(0..<101)
        var items: [Int: String] = [:]
        for id in ids { items[id] = itemJSON(id: id, title: "S\(id)") }

        let client = Client(fetch: firebaseMock(
            topstories: ids,
            items: items,
            recordURL: { url in await captured.record(url) }
        ))

        _ = try await client.frontPage(1)

        let itemIDs = (await captured.urls)
            .compactMap(\.firebaseItemID)
            .sorted()
        #expect(itemIDs == Array(50..<100))
    }

    @Test("synthesises totalPages from topstories.count")
    func totalPagesSynthesis() async throws {
        let mkClient: ([Int]) -> Client = { ids in
            Client(fetch: firebaseMock(
                topstories: ids,
                items: Dictionary(uniqueKeysWithValues:
                    ids.map { ($0, itemJSON(id: $0, title: "S")) }),
                recordURL: { _ in }
            ))
        }

        let p101 = try await mkClient(Array(0..<101)).frontPage(0)
        #expect(p101.totalPages == 3)

        let p100 = try await mkClient(Array(0..<100)).frontPage(0)
        #expect(p100.totalPages == 2)

        let pEmpty = try await mkClient([]).frontPage(0)
        #expect(pEmpty.totalPages == 0)
        #expect(pEmpty.stories.isEmpty)
    }

    @Test("drops deleted, dead, and incomplete items")
    func dropsBadItems() async throws {
        let client = Client(fetch: firebaseMock(
            topstories: [1, 2, 3, 4, 5],
            items: [
                1: itemJSON(id: 1, title: "Good"),
                2: itemJSON(id: 2, title: "Deleted", deleted: true),
                3: itemJSON(id: 3, title: "Dead", dead: true),
                4: itemJSON(id: 4, title: nil),
                5: itemJSON(id: 5, title: "NoAuthor", by: nil),
            ],
            recordURL: { _ in }
        ))

        let page = try await client.frontPage(0)

        #expect(page.stories.map(\.id) == ["1"])
    }

    @Test("tolerates per-item fetch failures")
    func toleratesItemFailures() async throws {
        let client = Client(fetch: { request in
            let url = request.url!
            if url.path.hasSuffix("/topstories.json") {
                return okResponse("[1,2,3]", for: url)
            }
            if url.path.hasSuffix("/item/2.json") {
                throw URLError(.notConnectedToInternet)
            }
            if let id = url.firebaseItemID {
                return okResponse(itemJSON(id: id, title: "S\(id)"), for: url)
            }
            throw URLError(.fileDoesNotExist)
        })

        let page = try await client.frontPage(0)

        #expect(page.stories.map(\.id) == ["1", "3"])
    }

    @Test("decodes Firebase item time as Unix epoch seconds")
    func decodesEpochTime() async throws {
        let client = Client(fetch: firebaseMock(
            topstories: [1],
            items: [
                1: """
                {"id":1,"by":"alice","title":"T","time":1700000000,"score":5,"descendants":2,"type":"story"}
                """,
            ],
            recordURL: { _ in }
        ))

        let page = try await client.frontPage(0)
        let story = try #require(page.stories.first)

        #expect(story.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(story.score == 5)
        #expect(story.commentCount == 2)
    }
}

@Suite("Client.search (Algolia)")
struct AlgoliaSearchTests {

    @Test("hits the search endpoint with the requested query and page")
    func searchURL() async throws {
        let captured = CapturedURLs()
        let client = Client(fetch: { request in
            await captured.record(request.url)
            return okResponse(#"{"hits":[],"nbPages":0}"#, for: request.url!)
        })

        _ = try await client.search("rust async", 3)

        let url = try #require((await captured.urls).first)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "hn.algolia.com")
        #expect(components.path == "/api/v1/search")
        let items = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["query"] == "rust async")
        #expect(items["tags"] == "story")
        #expect(items["hitsPerPage"] == "50")
        #expect(items["page"] == "3")
    }

    @Test("decodes Algolia envelope into a paginated Page")
    func decodesEnvelope() async throws {
        let client = Client(fetch: { request in
            okResponse(Self.envelopeFixture, for: request.url!)
        })

        let result = try await client.search("anything", 0)

        #expect(result.stories.count == 2)
        #expect(result.totalPages == 12)
        let first = try #require(result.stories.first)
        #expect(first.id == "39184235")
        #expect(first.title == "Show HN: Tiny example")
        #expect(first.author == "alice")
        #expect(first.score == 142)
        #expect(first.commentCount == 23)
        #expect(first.url == "https://example.com/show")
    }

    @Test("skips hits missing title or author")
    func skipsIncompleteHits() async throws {
        let client = Client(fetch: { request in
            okResponse(Self.partialFixture, for: request.url!)
        })

        let result = try await client.search("x", 0)

        #expect(result.stories.count == 1)
        #expect(result.stories.first?.id == "1")
    }

    static let envelopeFixture: String = #"""
    {
      "hits": [
        {
          "objectID": "39184235",
          "title": "Show HN: Tiny example",
          "author": "alice",
          "points": 142,
          "num_comments": 23,
          "url": "https://example.com/show",
          "created_at": "2026-05-04T08:21:00.000Z"
        },
        {
          "objectID": "39184236",
          "title": "Linkless Ask HN",
          "author": "bob",
          "points": 12,
          "num_comments": 4,
          "url": null,
          "created_at": "2026-05-04T08:22:00.000Z"
        }
      ],
      "nbPages": 12
    }
    """#

    static let partialFixture: String = #"""
    {
      "hits": [
        {
          "objectID": "1",
          "title": "Has both",
          "author": "carol",
          "points": 1,
          "num_comments": 0,
          "url": null,
          "created_at": "2026-05-04T08:00:00.000Z"
        },
        {
          "objectID": "2",
          "title": null,
          "author": "dave",
          "points": 1,
          "num_comments": 0,
          "url": null,
          "created_at": "2026-05-04T08:01:00.000Z"
        },
        {
          "objectID": "3",
          "title": "No author",
          "author": null,
          "points": 1,
          "num_comments": 0,
          "url": null,
          "created_at": "2026-05-04T08:02:00.000Z"
        }
      ],
      "nbPages": 1
    }
    """#
}

// MARK: - Helpers

/// Actor-wrapped capture so the `@Sendable` fetch closure can record
/// URLs from any executor without crossing isolation boundaries with a
/// non-Sendable mutable.
private actor CapturedURLs {
    private(set) var urls: [URL] = []
    func record(_ url: URL?) { if let url { urls.append(url) } }
}

/// Build a fetch closure that dispatches by URL shape: `topstories.json`
/// returns the given ID list, `item/{id}.json` returns the body keyed by
/// that ID, and `recordURL` is invoked for every request. Missing items
/// throw `URLError(.fileDoesNotExist)` so tests fail loudly if they
/// forget to register a fixture.
private func firebaseMock(
    topstories: [Int],
    items: [Int: String],
    recordURL: @escaping @Sendable (URL) async -> Void
) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
    { request in
        let url = request.url!
        await recordURL(url)
        if url.path.hasSuffix("/topstories.json") {
            let json = "[\(topstories.map(String.init).joined(separator: ","))]"
            return okResponse(json, for: url)
        }
        if let id = url.firebaseItemID, let body = items[id] {
            return okResponse(body, for: url)
        }
        throw URLError(.fileDoesNotExist)
    }
}

/// Minimal Firebase item JSON. `nil` for `title`/`by` lets tests exercise
/// the filter that drops items missing required fields.
private func itemJSON(
    id: Int,
    title: String?,
    by: String? = "alice",
    score: Int = 1,
    descendants: Int = 0,
    url: String? = nil,
    time: TimeInterval = 1_700_000_000,
    deleted: Bool = false,
    dead: Bool = false
) -> String {
    var fields: [String] = ["\"id\":\(id)"]
    if let by { fields.append("\"by\":\"\(by)\"") }
    if let title { fields.append("\"title\":\"\(title)\"") }
    if let url { fields.append("\"url\":\"\(url)\"") }
    fields.append("\"score\":\(score)")
    fields.append("\"descendants\":\(descendants)")
    fields.append("\"time\":\(Int(time))")
    fields.append("\"type\":\"story\"")
    if deleted { fields.append("\"deleted\":true") }
    if dead { fields.append("\"dead\":true") }
    return "{\(fields.joined(separator: ","))}"
}

extension URL {
    /// Extract the numeric ID from a Firebase `item/{id}.json` URL.
    /// Returns `nil` for any other path.
    var firebaseItemID: Int? {
        let path = self.path
        let prefix = "/v0/item/"
        let suffix = ".json"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let mid = path.dropFirst(prefix.count).dropLast(suffix.count)
        return Int(mid)
    }
}
