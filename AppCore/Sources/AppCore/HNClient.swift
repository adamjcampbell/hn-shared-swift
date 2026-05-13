import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client for the Algolia Hacker News search API.
///
/// **Closure-struct shape, not a class.** The struct holds two
/// `@Sendable` closure properties — `frontPage` and `search` — which
/// `AppCoreActor` calls. This is the natural mock point: tests inject
/// closures directly without going through `URLSession` or
/// `URLProtocol`. Production callers use the no-arg `init()`, which
/// wires the closures to `URLSession.shared`-style live HTTP.
///
/// **`Sendable`.** All properties are `@Sendable` closures of
/// `Sendable` types, so the whole struct is `Sendable`. That's what
/// makes the cancel-and-replace pattern in `AppCoreActor` work: the
/// unstructured `Task` that issues the HTTP call captures `[client]`
/// directly, with no `self` capture, so the closure has no
/// non-Sendable region to send across.
///
/// **Cancellation.** The live closures call `URLSession.data(from:)`,
/// which throws `CancellationError` when the surrounding `Task` is
/// cancelled. Test closures use the project's `TestClock` to make
/// cancellation deterministic.
public struct HNClient: Sendable {
    public var frontPage: @Sendable (_ page: Int) async throws -> HNPage
    public var search: @Sendable (_ query: String, _ page: Int) async throws -> HNPage

    public init(
        frontPage: @escaping @Sendable (_ page: Int) async throws -> HNPage,
        search: @escaping @Sendable (_ query: String, _ page: Int) async throws -> HNPage
    ) {
        self.frontPage = frontPage
        self.search = search
    }
}

/// The decoded result of one page fetch — the hits for the page plus
/// the envelope's `nbPages`, which `LoadableHits.receiveInitialPage` /
/// `receiveLoadMorePage` need to drive `hasMore`.
public struct HNPage: Sendable, Equatable {
    public let hits: [HNHit]
    public let totalPages: Int

    public init(hits: [HNHit], totalPages: Int) {
        self.hits = hits
        self.totalPages = totalPages
    }
}

extension HNClient {
    /// Live implementation hitting `hn.algolia.com/api/v1`.
    public init() {
        let session = HNClient.productionSession
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
                let request = HNClient.frontPageRequest(page: page)
                let (data, _) = try await fetch(request)
                return try HNClient.decode(data)
            },
            search: { query, page in
                let request = HNClient.searchRequest(query: query, page: page)
                let (data, _) = try await fetch(request)
                return try HNClient.decode(data)
            }
        )
    }

    private static let baseURL = URL(string: "https://hn.algolia.com/api/v1/")!

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let productionSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        // `waitsForConnectivity` is read-only on swift-corelibs-Foundation
        // (Android/Linux), so we don't touch it. The default (`false`) is
        // what we want anyway.
        return URLSession(configuration: configuration)
    }()

    static func frontPageRequest(page: Int) -> URLRequest {
        makeRequest(path: "search_by_date", queryItems: [
            URLQueryItem(name: "tags", value: "front_page"),
            URLQueryItem(name: "hitsPerPage", value: "50"),
            URLQueryItem(name: "page", value: String(page)),
        ])
    }

    static func searchRequest(query: String, page: Int) -> URLRequest {
        makeRequest(path: "search", queryItems: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "tags", value: "story"),
            URLQueryItem(name: "hitsPerPage", value: "50"),
            URLQueryItem(name: "page", value: String(page)),
        ])
    }

    private static func makeRequest(path: String, queryItems: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(
            url: HNClient.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = queryItems
        return URLRequest(url: components.url!)
    }

    static func decode(_ data: Data) throws -> HNPage {
        let response = try HNClient.decoder.decode(HNSearchResponse.self, from: data)
        return HNPage(
            hits: response.hits.compactMap(HNHit.init(payload:)),
            totalPages: response.nbPages
        )
    }
}

private struct HNSearchResponse: Decodable {
    let hits: [HNStoryPayload]
    let nbPages: Int
}

private struct HNStoryPayload: Decodable {
    let objectID: String
    let title: String?
    let author: String?
    let points: Int?
    let num_comments: Int?
    let url: String?
    let created_at: Date
}

private extension HNHit {
    init?(payload: HNStoryPayload) {
        guard let title = payload.title, let author = payload.author else { return nil }
        self.init(
            id: payload.objectID,
            title: title,
            author: author,
            points: payload.points ?? 0,
            commentCount: payload.num_comments ?? 0,
            url: payload.url,
            createdAt: payload.created_at
        )
    }
}
