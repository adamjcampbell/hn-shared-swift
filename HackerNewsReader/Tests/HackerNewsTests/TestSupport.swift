import Foundation
@testable import HackerNewsReader
import HackerNews

/// Canned 200 OK `(Data, URLResponse)` for the closure-injected fetch
/// seam in `Client(fetch:)`. The response is typed as `URLResponse`
/// (not `HTTPURLResponse`) to match the fetch closure's signature.
func okResponse(_ json: String, for url: URL) -> (Data, URLResponse) {
    let response: URLResponse = HTTPURLResponse(
        url: url, statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(json.utf8), response)
}
