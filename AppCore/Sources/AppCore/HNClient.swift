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
        self.init(session: HNClient.productionSession)
    }

    /// Test seam for URL-construction tests that want to drive the
    /// live HTTP path through a `URLProtocol`-stubbed `URLSession`.
    /// Module-internal so production callers can't pass a session by
    /// accident.
    init(session: URLSession) {
        self.init(
            frontPage: { page in
                try await HNClient.fetch(
                    session: session,
                    path: "search_by_date",
                    queryItems: [
                        URLQueryItem(name: "tags", value: "front_page"),
                        URLQueryItem(name: "hitsPerPage", value: "50"),
                        URLQueryItem(name: "page", value: String(page)),
                    ]
                )
            },
            search: { query, page in
                try await HNClient.fetch(
                    session: session,
                    path: "search",
                    queryItems: [
                        URLQueryItem(name: "query", value: query),
                        URLQueryItem(name: "tags", value: "story"),
                        URLQueryItem(name: "hitsPerPage", value: "50"),
                        URLQueryItem(name: "page", value: String(page)),
                    ]
                )
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

    private static func fetch(
        session: URLSession,
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> HNPage {
        var components = URLComponents(
            url: HNClient.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = queryItems
        let (data, _) = try await session.data(from: components.url!)
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
