import Foundation
@testable import AppCore

// Tests that touch `URLProtocolStub`'s static state must run serially.
// `.serialized` only serialises within a single suite; Swift Testing
// parallelises across suites by default. The pragmatic fix is to invoke
// `swift test --no-parallel` (see `AGENT.md`'s testing section). A global-
// actor approach (e.g. `@globalActor TestNetworkLock`) was tried and did
// *not* serialise across suites under the current Swift Testing runner.

/// Lightweight `URLProtocol` stub that lets a test inject canned
/// (data, response) tuples in front of any `URLSession` whose
/// configuration registers it.
///
/// This uses `nonisolated(unsafe) static var` for storage; tests that
/// touch it must run inside a `.serialized` suite (Swift Testing
/// parallelises by default). `nonisolated(unsafe)` is acceptable in
/// `Tests/` even though `Sources/` forbids it — see `AGENT.md`.
final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Data, HTTPURLResponse))?
    nonisolated(unsafe) static var requestRecorder: ((URLRequest) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestRecorder?(request)
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (data, response) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        responder = nil
        requestRecorder = nil
    }
}

func makeStubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolStub.self]
    return URLSession(configuration: configuration)
}

func okResponse(_ json: String, for url: URL) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: url, statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(json.utf8), response)
}
