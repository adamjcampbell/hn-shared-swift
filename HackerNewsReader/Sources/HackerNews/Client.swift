import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client for the Hacker News data APIs.
///
/// Two transports sit behind one closure-bag: ``frontPage`` hits the
/// official Firebase HN API for the live front-page ranking,
/// ``search`` hits the Algolia HN search API for text search. Both
/// closures resolve to a ``Page``, so callers don't see the
/// difference. Tests can inject closures directly; production callers
/// use the no-argument ``init()`` to wire the live `URLSession`.
public struct Client: Sendable {
    public var frontPage: @Sendable (_ page: Int) async throws -> Page
    public var search: @Sendable (_ query: String, _ page: Int) async throws -> Page

    /// Builds a client from explicit transport closures.
    ///
    /// - Parameters:
    ///   - frontPage: Resolves a zero-indexed page of the front-page
    ///     ranking.
    ///   - search: Resolves a zero-indexed page of search results for
    ///     a query.
    public init(
        frontPage: @escaping @Sendable (_ page: Int) async throws -> Page,
        search: @escaping @Sendable (_ query: String, _ page: Int) async throws -> Page
    ) {
        self.frontPage = frontPage
        self.search = search
    }

    /// Builds a test client whose closures return empty pages by
    /// default. Override only the closures the test exercises.
    ///
    /// - Parameters:
    ///   - frontPage: Front-page closure; defaults to an empty page.
    ///   - search: Search closure; defaults to an empty page.
    /// - Returns: A ``Client`` with the supplied closures installed.
    public static func mock(
        frontPage: @escaping @Sendable (_ page: Int) async throws -> Page = { _ in Page(stories: [], totalPages: 0) },
        search: @escaping @Sendable (_ query: String, _ page: Int) async throws -> Page = { _, _ in Page(stories: [], totalPages: 0) }
    ) -> Client {
        Client(frontPage: frontPage, search: search)
    }
}

extension Client {
    /// Page size used for both transports.
    static let pageSize = 50

    /// Builds a live client backed by a shared `URLSession`.
    public init() {
        let session = Client.productionSession
        self.init(fetch: { request in
            try await session.data(for: request)
        })
    }

    /// Builds a client over an injected HTTP transport — the test seam
    /// for asserting on the exact `URLRequest` and returning canned
    /// `(Data, URLResponse)` without `URLSession` or `URLProtocol`.
    ///
    /// - Parameter fetch: The transport closure to use for both
    ///   front-page and search requests.
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

    /// Fetches one page of the Firebase front-page feed, dropping
    /// items that fail individually.
    ///
    /// One request resolves the ranked id list; up to ``pageSize``
    /// item fetches then run in parallel. Per-item failures are
    /// elided from the returned page rather than failing the whole
    /// request — mirrors the Algolia path's tolerance for hits
    /// missing required fields.
    ///
    /// - Parameters:
    ///   - page: Zero-indexed page within the ranked id list.
    ///   - fetch: HTTP transport used for the id list and each item.
    /// - Returns: The decoded page; may be shorter than ``pageSize``
    ///   if some item fetches failed.
    /// - Throws: Transport, decoding, or cancellation errors. Per-item
    ///   transport failures are swallowed; cancellation tears down
    ///   the in-flight task group.
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
