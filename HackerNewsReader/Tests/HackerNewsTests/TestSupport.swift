import Foundation
import HackerNews
import PlatformSupport

/// Canned HTTP response for the injected transport.
func okResponse(_ json: String, for url: URL) -> HTTPResponse {
    HTTPResponse(body: Data(json.utf8), statusCode: 200)
}
