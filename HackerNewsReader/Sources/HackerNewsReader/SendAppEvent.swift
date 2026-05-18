import Foundation

/// Capability-style action returned by `makeAppCore()` and installed
/// into SwiftUI's environment as `\.sendEvent`. Mirrors the ergonomic
/// of SwiftUI's `DismissAction`: child views call `sendEvent(.foo)`
/// without ever holding a reference to the internal `AppCore`.
///
/// Holds the `AppCore` directly rather than an arbitrary closure so it
/// can implement `Equatable` via `===` on the held identity. Without
/// `Equatable`, SwiftUI's reflection-based environment diff would
/// treat the value as changed on every parent body re-evaluation —
/// closures are neither equatable nor reference-comparable — and
/// invalidate every descendant reading `\.sendEvent`.
///
/// The reference is optional so the default-init `SendAppEvent()` is a
/// real no-op for previews and the default env value, with no
/// throwaway `AppCore` allocation.
///
/// Methods are nonisolated: every dispatch funnels through
/// `core.sendEvent`, whose actor hop is the synchronization point —
/// a `@MainActor` pin would just constrain callers and would force
/// `Equatable` to infer as `@MainActor`-isolated, which SwiftUI's
/// env diff (called from arbitrary contexts) can't tolerate.
// SKIP @bridgeMembers
public struct SendAppEvent: Sendable, Equatable {
    private let core: AppCore?

    public init() { self.core = nil }
    init(_ core: AppCore) { self.core = core }

    /// SwiftUI ergonomic — `sendEvent(.foo)` mirrors `DismissAction`.
    /// Pure sugar over `send(_:)`. Skip can't yet bridge
    /// `callAsFunction` (operator lowering), so Kotlin callers use
    /// `send(_:)` directly.
    // SKIP @nobridge
    public func callAsFunction(_ event: AppEvent) { send(event) }

    /// Fire-and-forget. Spawns an unstructured Task so the call site
    /// stays synchronous; the handler runs to completion on that
    /// Task. Pair with `run(_:)` when the caller needs to await.
    public func send(_ event: AppEvent) { Task { await sendEvent(event) } }

    /// Awaitable counterpart of `send(_:)`. Suspends until the
    /// handler completes — use from `.refreshable` so the spinner
    /// stays visible until the fetch lands.
    public func run(_ event: AppEvent) async { await sendEvent(event) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.core === rhs.core
    }

    private func sendEvent(_ event: AppEvent) async {
        if let core { await core.sendEvent(event) }
    }
}
