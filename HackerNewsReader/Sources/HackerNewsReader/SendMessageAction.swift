import Foundation

/// Capability action for sending ``Message``s — installed into the
/// SwiftUI environment as `\.sendMessage` and mirroring the
/// ergonomic of `DismissAction`.
///
/// `Equatable` is an identity comparison on the owning ``Model`` (via
/// its `ObjectIdentifier`) so SwiftUI's environment diff treats the
/// action as stable across parent re-evaluations. The no-op action
/// keys on `Self` instead, so previews/defaults never compare equal to
/// a live action.
// SKIP @bridgeMembers
public struct SendMessageAction: Sendable, Equatable {
    typealias SendMessage = @MainActor (Message) async -> Void

    private let id: ObjectIdentifier
    private let sendMessage: SendMessage

    /// Creates a no-op action — the default environment value and
    /// the value used in previews.
    public init() {
        self.id = ObjectIdentifier(Self.self)
        self.sendMessage = { _ in }
    }

    init(id: ObjectIdentifier, sendMessage: @escaping SendMessage) {
        self.id = id
        self.sendMessage = sendMessage
    }

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

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
