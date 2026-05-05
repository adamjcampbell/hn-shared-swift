import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client for the Algolia Hacker News search API.
///
/// **Why a `final class` and not an `actor`:** the client has no shared
/// mutable state to protect — `baseURL`, `productionSession`, and
/// `decoder` are `static let` of well-known thread-safe types, and the
/// instance-level `session` is `let`. Methods are `async` and unannotated,
/// so under SE-0461 (`NonisolatedNonsendingByDefault`, enabled package-
/// wide) they run on the **caller's** actor: iOS calls run on `MainActor`,
/// Android calls run on the `AndroidBridge` actor. Promoting the class to
/// an actor would add two pointless hops per call without protecting
/// anything.
///
/// **`Sendable` conformance:** `HNClient` only holds `let` properties of
/// thread-safe types (`URLSession`, `JSONDecoder`, static `URL`). Marking
/// it `Sendable` is what makes the cancel-and-replace pattern in
/// `AppModel` possible: the unstructured `Task` that issues the HTTP
/// call captures `[client]` directly, with no `self` capture, so the
/// closure has no non-Sendable region to send across.
///
/// **Cancellation:** every method calls `URLSession.data(from:)`, which
/// throws `CancellationError` when the surrounding `Task` is cancelled.
/// `AppModel` relies on this for debounced search.
public final class HNClient: Sendable {
    private static let baseURL = URL(string: "https://hn.algolia.com/api/v1/")!

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let productionSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        // Note: `waitsForConnectivity` is read-only in swift-corelibs-
        // Foundation (Android/Linux), so we don't touch it. The default
        // is false on both platforms anyway.
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession

    public init() {
        self.session = Self.productionSession
    }

    /// Test-only initialiser. Module-internal so production callers can't
    /// pass a custom session by accident, but `AppCoreTests` can construct
    /// one wired to a `URLProtocol` stub.
    init(session: URLSession) {
        self.session = session
    }

    public func frontPage() async throws -> [Story] {
        try await fetch(
            path: "search_by_date",
            queryItems: [
                URLQueryItem(name: "tags", value: "front_page"),
                URLQueryItem(name: "hitsPerPage", value: "50"),
            ]
        )
    }

    public func search(_ query: String) async throws -> [Story] {
        try await fetch(
            path: "search",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "tags", value: "story"),
                URLQueryItem(name: "hitsPerPage", value: "50"),
            ]
        )
    }

    private func fetch(path: String, queryItems: [URLQueryItem]) async throws -> [Story] {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = queryItems
        let (data, _) = try await session.data(from: components.url!)
        let response = try Self.decoder.decode(HNSearchResponse.self, from: data)
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
