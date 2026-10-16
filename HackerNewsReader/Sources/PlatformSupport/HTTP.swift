#if os(Android)
import FoundationEssentials
#else
import Foundation
#endif

public struct HTTPResponse: Sendable {
    public let body: Data
    public let statusCode: Int

    public init(body: Data, statusCode: Int) {
        self.body = body
        self.statusCode = statusCode
    }
}

public enum HTTPError: Error, CustomStringConvertible {
    case status(Int)
    case transport(String)

    public var description: String {
        switch self {
        case .status(let code): "HTTP request failed (\(code))"
        case .transport(let message): message
        }
    }
}

#if !os(Android)
private let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 10
    return URLSession(configuration: configuration)
}()

public func fetch(_ url: URL) async throws -> HTTPResponse {
    do {
        let (body, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw HTTPError.transport("Expected an HTTP response")
        }
        return HTTPResponse(body: body, statusCode: response.statusCode)
    } catch let error as URLError where error.code == .cancelled {
        throw CancellationError()
    }
}

public func preferredLanguages() -> [String] { Locale.preferredLanguages }

public func formatTime(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .standard)
}
#endif
