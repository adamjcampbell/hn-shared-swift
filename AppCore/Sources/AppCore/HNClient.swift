import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client for the Algolia Hacker News search API.
///
/// **Closure-struct shape, not a class.** The struct holds two
/// `@Sendable` closure properties — `frontPage` and `search` — which
/// `AppModel` calls. This is the natural mock point: tests inject
/// closures directly without going through `URLSession` or
/// `URLProtocol`. Production callers use the no-arg `init()`, which
/// wires the closures to `URLSession.shared`-style live HTTP.
///
/// **`Sendable`.** All properties are `@Sendable` closures of
/// `Sendable` types, so the whole struct is `Sendable`. That's what
/// makes the cancel-and-replace pattern in `AppModel` work: the
/// unstructured `Task` that issues the HTTP call captures `[client]`
/// directly, with no `self` capture, so the closure has no
/// non-Sendable region to send across.
///
/// **Cancellation.** The live closures call `URLSession.data(from:)`,
/// which throws `CancellationError` when the surrounding `Task` is
/// cancelled. Test closures use the project's `TestClock` to make
/// cancellation deterministic.
public struct HNClient: Sendable {
    public var frontPage: @Sendable () async throws -> [Story]
    public var search: @Sendable (_ query: String) async throws -> [Story]

    public init(
        frontPage: @escaping @Sendable () async throws -> [Story],
        search: @escaping @Sendable (_ query: String) async throws -> [Story]
    ) {
        self.frontPage = frontPage
        self.search = search
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
            frontPage: {
                try await HNClient.fetch(
                    session: session,
                    path: "search_by_date",
                    queryItems: [
                        URLQueryItem(name: "tags", value: "front_page"),
                        URLQueryItem(name: "hitsPerPage", value: "50"),
                    ]
                )
            },
            search: { query in
                try await HNClient.fetch(
                    session: session,
                    path: "search",
                    queryItems: [
                        URLQueryItem(name: "query", value: query),
                        URLQueryItem(name: "tags", value: "story"),
                        URLQueryItem(name: "hitsPerPage", value: "50"),
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
    ) async throws -> [Story] {
        var components = URLComponents(
            url: HNClient.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = queryItems
        let (data, _) = try await session.data(from: components.url!)
        let response = try HNClient.decoder.decode(HNSearchResponse.self, from: data)
        return response.hits.compactMap(Story.init(hit:))
    }
}

private struct HNSearchResponse: Decodable {
    let hits: [HNStoryHit]
}

private struct HNStoryHit: Decodable {
    let objectID: String
    let title: String?
    let author: String?
    let points: Int?
    let num_comments: Int?
    let url: String?
    let created_at: Date
}

private extension Story {
    init?(hit: HNStoryHit) {
        guard let title = hit.title, let author = hit.author else { return nil }
        self.init(
            id: hit.objectID,
            title: title,
            author: author,
            points: hit.points ?? 0,
            commentCount: hit.num_comments ?? 0,
            url: hit.url,
            createdAt: hit.created_at
        )
    }
}
