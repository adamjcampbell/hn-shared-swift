import Foundation

/// Capability action for sending ``Message``s — installed into the
/// SwiftUI environment as `\.sendMessage` and mirroring the
/// ergonomic of `DismissAction`.
///
/// `@MainActor` on the entry points states the capability's contract
/// where callers read it and bridges to Android as a main-thread
/// assertion, so an off-main call from Kotlin traps rather than mutating
/// ``Model`` off-region.
///
/// `Equatable` discriminates only live from no-op: exactly one live action
/// is ever installed (app code builds it once from the process-lifetime
/// ``Core``), so SwiftUI's environment diff needs only to tell the real
/// action from the previews/defaults no-op, not to distinguish two live
/// actions. Android never consults this; the bridge compares the peer
/// object by identity.
// SKIP @bridgeMembers
public struct SendMessageAction: Sendable, Equatable {
    /// Which initializer produced this action.
    private enum Kind: Sendable { case noop, live }

    typealias SendMessage = @MainActor (Message) async -> Void

    private let kind: Kind
    private let sendMessage: SendMessage

    /// Creates a no-op action — the default environment value and
    /// the value used in previews.
    public init() {
        self.kind = .noop
        self.sendMessage = { _ in }
    }

    /// Wraps a ``Core``'s send capability in the `@MainActor` action the
    /// UI installs. Built by app code from the handle ``makeAppCore()``
    /// returns; the `@MainActor` boundary is established here rather than
    /// inside ``Core``, so the same isolation-generic `Core` serves tests
    /// (raw closure on a `TestActor`) and production.
    ///
    /// - Parameter core: The handle to dispatch through.
    @MainActor public init(_ core: Core) {
        self.kind = .live
        self.sendMessage = { await core.sendMessage($0) }
    }

    /// SwiftUI ergonomic equivalent of ``send(_:)``.
    ///
    /// - Parameter message: The message to dispatch.
    // SKIP @nobridge
    @MainActor public func callAsFunction(_ message: Message) { send(message) }

    /// Dispatches a message fire-and-forget on an unstructured `Task`.
    ///
    /// `@MainActor` keeps concurrent `send`s ordered: the `Task` inherits
    /// the main actor from this method, so it enqueues there in call order
    /// rather than racing on the shared executor. Order holds up to each
    /// handler's first suspension point; ``run(_:)`` awaits the whole
    /// handler.
    ///
    /// - Parameter message: The message to dispatch.
    @MainActor public func send(_ message: Message) { Task { await sendMessage(message) } }

    /// Awaitable counterpart of ``send(_:)``; suspends until the
    /// handler completes. Use from `.refreshable` so the spinner
    /// stays visible until the fetch lands.
    ///
    /// - Parameter message: The message to dispatch.
    @MainActor public func run(_ message: Message) async { await sendMessage(message) }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.kind == rhs.kind }
}
