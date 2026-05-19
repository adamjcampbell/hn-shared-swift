import Foundation

/// Capability action for sending ``AppEvent``s — installed into the
/// SwiftUI environment as `\.sendEvent` and mirroring the ergonomic
/// of `DismissAction`.
///
/// `Equatable` is implemented as identity comparison on the held
/// `AppEngine` so SwiftUI's environment diff treats the action as
/// stable across parent re-evaluations.
// SKIP @bridgeMembers
public struct SendAppEvent: Sendable, Equatable {
    private let engine: AppEngine?

    /// Creates a no-op action — the default environment value and
    /// the value used in previews.
    public init() { self.engine = nil }
    init(_ engine: AppEngine) { self.engine = engine }

    /// SwiftUI ergonomic equivalent of ``send(_:)``.
    ///
    /// - Parameter event: The event to dispatch.
    // SKIP @nobridge
    public func callAsFunction(_ event: AppEvent) { send(event) }

    /// Dispatches an event fire-and-forget on an unstructured `Task`.
    ///
    /// - Parameter event: The event to dispatch.
    public func send(_ event: AppEvent) { Task { await sendEvent(event) } }

    /// Awaitable counterpart of ``send(_:)``; suspends until the
    /// handler completes. Use from `.refreshable` so the spinner
    /// stays visible until the fetch lands.
    ///
    /// - Parameter event: The event to dispatch.
    public func run(_ event: AppEvent) async { await sendEvent(event) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.engine === rhs.engine
    }

    private func sendEvent(_ event: AppEvent) async {
        if let engine { await engine.sendEvent(event) }
    }
}
