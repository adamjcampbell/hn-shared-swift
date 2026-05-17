import Foundation

/// Activity status for a single in-flight operation against a surface
/// (initial fetch / refresh, or load-more). Orthogonal to the data
/// result — `AppState` holds independent `LoadStatus` values per
/// lifecycle axis so they can run concurrently.
///
/// `startLoading()` does **not** clear `error`. A stale banner
/// persists through a retry until either success clears it or another
/// failure replaces it.
// SKIP @bridgeMembers
public struct LoadStatus: Sendable, Equatable {
    public var isLoading: Bool
    public var error: String?

    public init(isLoading: Bool = false, error: String? = nil) {
        self.isLoading = isLoading
        self.error = error
    }

    public mutating func startLoading() {
        isLoading = true
    }

    public mutating func finishSuccess() {
        isLoading = false
        error = nil
    }

    public mutating func finishFailure(_ message: String) {
        isLoading = false
        error = message
    }
}
