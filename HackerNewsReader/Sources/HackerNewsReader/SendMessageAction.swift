import Foundation

/// Capability action for sending ``Message``s — installed into the
/// SwiftUI environment as `\.sendMessage` and mirroring the
/// ergonomic of `DismissAction`.
///
/// `Equatable` is implemented as identity comparison on the held
/// ``Engine`` so SwiftUI's environment diff treats the action as
/// stable across parent re-evaluations.
// SKIP @bridgeMembers
public struct SendMessageAction: Sendable, Equatable {
    private let engine: Engine?

    /// Creates a no-op action — the default environment value and
    /// the value used in previews.
    public init() { self.engine = nil }
    init(_ engine: Engine) { self.engine = engine }

    /// SwiftUI ergonomic equivalent of ``send(_:)``.
    ///
    /// - Parameter message: The message to dispatch.
    // SKIP @nobridge
    public func callAsFunction(_ message: Message) { send(message) }

    /// Dispatches a message fire-and-forget on an unstructured `Task`.
    ///
    /// - Parameter message: The message to dispatch.
    public func send(_ message: Message) { Task { await sendMessage(message) } }

    /// Awaitable counterpart of ``send(_:)``; suspends until the
    /// handler completes. Use from `.refreshable` so the spinner
    /// stays visible until the fetch lands.
    ///
    /// - Parameter message: The message to dispatch.
    public func run(_ message: Message) async { await sendMessage(message) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.engine === rhs.engine
    }

    private func sendMessage(_ message: Message) async {
        if let engine { await engine.sendMessage(message) }
    }
}
