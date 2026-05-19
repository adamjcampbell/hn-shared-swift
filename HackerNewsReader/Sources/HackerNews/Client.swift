import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client for the Hacker News data APIs.
///
/// **Two transports behind one closure-bag.** `frontPage` hits the
/// official Firebase HN API (`hacker-news.firebaseio.com/v0`) — only
/// that endpoint returns the live front-page ordering. `search` hits the
/// Algolia HN search API (`hn.algolia.com/api/v1`) because Firebase has
/// no text-search endpoint. Callers don't see the difference: both
/// closures return a `Page`.
///
/// **Closure-struct shape, not a class.** Tests inject closures directly
/// without going through `URLSession` or `URLProtocol`. Production
/// callers use the no-arg `init()`, which wires the closures to a live
/// `URLSession`.
///
/// **`Sendable`.** All properties are `@Sendable` closures of `Sendable`
/// types, so the whole struct is `Sendable`. That's what makes the
/// cancel-and-replace pattern in the reader's `AppCore` work: the
/// unstructured `Task` that issues the HTTP call captures `[client]`
/// directly, with no `self` capture, so the closure has no
/// non-Sendable region to send across.
///
/// **Cancellation.** The live closures call `URLSession.data(for:)`,
/// which throws `URLError(.cancelled)` when the surrounding `Task` is
/// cancelled. For `frontPage`, cancellation propagates into the
/// `withThrowingTaskGroup` over per-item fetches automatically.
public struct Client: Sendable {
    public var frontPage: @Sendable (_ page: Int) async throws -> Page
    public var search: @Sendable (_ query: String, _ page: Int) async throws -> Page

    public init(
        frontPage: @escaping @Sendable (_ page: Int) async throws -> Page,
        search: @escaping @Sendable (_ query: String, _ page: Int) async throws -> Page
    ) {
        self.frontPage = frontPage
        self.search = search
    }

    /// Test convenience: pre-filled defaults that return empty pages.
    /// Override only the closure(s) the test cares about.
    public static func mock(
        frontPage: @escaping @Sendable (_ page: Int) async throws -> Page = { _ in Page(stories: [], totalPages: 0) },
        search: @escaping @Sendable (_ query: String, _ page: Int) async throws -> Page = { _, _ in Page(stories: [], totalPages: 0) }
    ) -> Client {
        Client(frontPage: frontPage, search: search)
    }
}

extension Client {
    /// Page size used for both transports. Algolia gets it as a query
    /// parameter; Firebase's `topstories.json` returns a flat ID list
    /// that we slice locally.
    static let pageSize = 50

    /// Live implementation. Wires both transports to a shared
    /// `URLSession`.
    public init() {
        let session = Client.productionSession
        self.init(fetch: { request in
            try await session.data(for: request)
        })
    }

    /// Test seam: inject the HTTP transport directly. Lets tests assert
    /// on the exact `URLRequest` and return canned `(Data, URLResponse)`
    /// without any `URLSession` / `URLProtocol` machinery. Module-
    /// internal so production callers can't bypass `init()` by accident.
    init(fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.init(
            frontPage: { page in
                try await Client.firebaseFrontPage(page: page, fetch: fetch)
            },
            search: { query, page in
                let request = Client.searchRequest(query: query, page: page)
                let (data, _) = try await fetch(request)
                return try Client.decodeAlgoliaSearch(data)
            }
        )
    }

    static let productionSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        // `waitsForConnectivity` is read-only on swift-corelibs-Foundation
        // (Android/Linux), so we don't touch it. The default (`false`) is
        // what we want anyway.
        return URLSession(configuration: configuration)
    }()
}

// MARK: - Firebase front-page transport

extension Client {
    static let firebaseBaseURL = URL(string: "https://hacker-news.firebaseio.com/v0/")!

    static let firebaseDecoder = JSONDecoder()

    static func topStoriesRequest() -> URLRequest {
        URLRequest(url: firebaseBaseURL.appendingPathComponent("topstories.json"))
    }

    static func firebaseItemRequest(id: Int) -> URLRequest {
        URLRequest(url: firebaseBaseURL.appendingPathComponent("item/\(id).json"))
    }

    /// Fetch one page of the front page via Firebase. Cost: 1 request
    /// for the IDs list (small) + up to `pageSize` parallel item
    /// fetches. Per-item failures are dropped (page returns
    /// `count - failed`) rather than failing the whole page — mirrors
    /// the Algolia path's tolerance for hits missing required fields.
    static func firebaseFrontPage(
        page: Int,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> Page {
        let (idsData, _) = try await fetch(topStoriesRequest())
        let allIDs = try firebaseDecoder.decode([Int].self, from: idsData)

        let totalPages = (allIDs.count + pageSize - 1) / pageSize
        let start = page * pageSize
        guard start < allIDs.count else {
            return Page(stories: [], totalPages: totalPages)
        }
        let end = min(start + pageSize, allIDs.count)
        let pageIDs = Array(allIDs[start..<end])

        // TaskGroup yields children in completion order, not submission
        // order — track the index explicitly so the final array follows
        // the topstories ranking.
        let indexed: [(Int, Story?)] = try await withThrowingTaskGroup(
            of: (Int, Story?).self
        ) { group in
            for (idx, id) in pageIDs.enumerated() {
                group.addTask {
                    do {
                        let (data, _) = try await fetch(firebaseItemRequest(id: id))
                        let item = try firebaseDecoder.decode(FirebaseItem.self, from: data)
                        return (idx, Story(firebaseItem: item))
                    } catch is CancellationError {
                        // Re-throw cancellation so the group tears down
                        // the rest of the in-flight requests. Without
                        // this, parent-Task cancellation gets swallowed
                        // here and the group keeps fetching.
                        throw CancellationError()
                    } catch let urlError as URLError where urlError.code == .cancelled {
                        throw CancellationError()
                    } catch {
                        return (idx, nil)
                    }
                }
            }
            var results: [(Int, Story?)] = []
            for try await result in group { results.append(result) }
            return results
        }

        let stories = indexed
            .sorted { $0.0 < $1.0 }
            .compactMap { $0.1 }
        return Page(stories: stories, totalPages: totalPages)
    }
}

private struct FirebaseItem: Decodable {
    let id: Int
    let by: String?
    let title: String?
    let url: String?
    let score: Int?
    let descendants: Int?
    let time: TimeInterval
    let type: String?
    let deleted: Bool?
    let dead: Bool?
}

private extension Story {
    init?(firebaseItem item: FirebaseItem) {
        guard item.deleted != true, item.dead != true else { return nil }
        guard let title = item.title, let by = item.by else { return nil }
        self.init(
            id: String(item.id),
            title: title,
            author: by,
            score: item.score ?? 0,
            commentCount: item.descendants ?? 0,
            url: item.url,
            createdAt: Date(timeIntervalSince1970: item.time)
        )
    }
}

// MARK: - Algolia search transport

extension Client {
    static let algoliaBaseURL = URL(string: "https://hn.algolia.com/api/v1/")!

    static let algoliaDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func searchRequest(query: String, page: Int) -> URLRequest {
        makeAlgoliaRequest(path: "search", queryItems: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "tags", value: "story"),
            URLQueryItem(name: "hitsPerPage", value: String(pageSize)),
            URLQueryItem(name: "page", value: String(page)),
        ])
    }

    private static func makeAlgoliaRequest(path: String, queryItems: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(
            url: algoliaBaseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = queryItems
        return URLRequest(url: components.url!)
    }

    static func decodeAlgoliaSearch(_ data: Data) throws -> Page {
        let response = try algoliaDecoder.decode(AlgoliaSearchResponse.self, from: data)
        return Page(
            stories: response.hits.compactMap(Story.init(algoliaHit:)),
            totalPages: response.nbPages
        )
    }
}

private struct AlgoliaSearchResponse: Decodable {
    let hits: [AlgoliaHit]
    let nbPages: Int
}

private struct AlgoliaHit: Decodable {
    let objectID: String
    let title: String?
    let author: String?
    let points: Int?
    let num_comments: Int?
    let url: String?
    let created_at: Date
}

private extension Story {
    init?(algoliaHit hit: AlgoliaHit) {
        guard let title = hit.title, let author = hit.author else { return nil }
        self.init(
            id: hit.objectID,
            title: title,
            author: author,
            score: hit.points ?? 0,
            commentCount: hit.num_comments ?? 0,
            url: hit.url,
            createdAt: hit.created_at
        )
    }
}
