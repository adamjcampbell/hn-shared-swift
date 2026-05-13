import Foundation
import Testing
@testable import AppCore

@Suite("HNClient")
struct HNClientTests {

    @Test("frontPage decodes Algolia envelope into a paginated HNPage")
    func frontPage_decodesEnvelope() async throws {
        let client = HNClient(fetch: { request in
            okResponse(Self.frontPageFixture, for: request.url!)
        })
        let result = try await client.frontPage(0)

        #expect(result.hits.count == 2)
        #expect(result.totalPages == 12)
        let first = try #require(result.hits.first)
        #expect(first.id == "39184235")
        #expect(first.title == "Show HN: Tiny example")
        #expect(first.author == "alice")
        #expect(first.points == 142)
        #expect(first.commentCount == 23)
        #expect(first.url == "https://example.com/show")
    }

    @Test("frontPage hits the search_by_date front_page endpoint with the requested page")
    func frontPage_hitsCorrectEndpoint() async throws {
        let captured = CapturedRequest()
        let client = HNClient(fetch: { request in
            await captured.record(request.url)
            return okResponse(#"{"hits":[],"nbPages":0}"#, for: request.url!)
        })
        _ = try await client.frontPage(2)

        let url = try #require(await captured.url)
        #expect(url.path == "/api/v1/search_by_date")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["tags"] == "front_page")
        #expect(items["hitsPerPage"] == "50")
        #expect(items["page"] == "2")
    }

    @Test("search builds the expected query string with the requested page")
    func search_buildsCorrectQueryString() async throws {
        let captured = CapturedRequest()
        let client = HNClient(fetch: { request in
            await captured.record(request.url)
            return okResponse(#"{"hits":[],"nbPages":0}"#, for: request.url!)
        })
        _ = try await client.search("rust async", 3)

        let url = try #require(await captured.url)
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

    @Test("decode skips hits missing title or author")
    func decode_skipsIncompleteHits() async throws {
        let client = HNClient(fetch: { request in
            okResponse(Self.partialFixture, for: request.url!)
        })
        let result = try await client.frontPage(0)

        #expect(result.hits.count == 1)
        #expect(result.hits.first?.id == "1")
    }
}

/// Actor-wrapped URL capture so the `@Sendable` fetch closure can record
/// without crossing isolation boundaries with a non-Sendable mutable.
private actor CapturedRequest {
    private(set) var url: URL?
    func record(_ url: URL?) { self.url = url }
}

extension HNClientTests {
    static let frontPageFixture: String = #"""
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
