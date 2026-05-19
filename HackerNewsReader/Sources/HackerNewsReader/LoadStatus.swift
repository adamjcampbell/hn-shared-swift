import Foundation

/// Activity status for a single in-flight operation against a
/// surface — the initial fetch / refresh, or a load-more.
// SKIP @bridgeMembers
public struct LoadStatus: Sendable, Equatable {
    public var isLoading: Bool
    public var error: String?

    /// Creates a status.
    ///
    /// - Parameters:
    ///   - isLoading: Whether an operation is currently in flight.
    ///   - error: Error message from the last failure, if any.
    public init(isLoading: Bool = false, error: String? = nil) {
        self.isLoading = isLoading
        self.error = error
    }

    /// Marks the operation as in flight.
    ///
    /// - Note: Leaves ``error`` set, so a stale banner persists
    ///   through a retry until either ``finishSuccess()`` clears it
    ///   or ``finishFailure(_:)`` replaces it.
    public mutating func startLoading() {
        isLoading = true
    }

    /// Clears ``isLoading`` and ``error``.
    public mutating func finishSuccess() {
        isLoading = false
        error = nil
    }

    /// Marks the operation as failed with `message`.
    ///
    /// - Parameter message: User-facing error description.
    public mutating func finishFailure(_ message: String) {
        isLoading = false
        error = message
    }
}
