import Foundation
import Observation

/// `@MainActor`-pinned UI-facing shell. Bridged to Kotlin via Skip;
/// SwiftUI and Compose both consume this type.
///
/// Owns `AppState` and the commands stream. Delegates all orchestration
/// to an `AppCore` workhorse — a non-Sendable `final class` whose
/// methods inherit isolation via `isolation: isolated (any Actor)?
/// = #isolation` (SE-0420). Because the workhorse is constructed and
/// only ever called from this `@MainActor` shell, every workhorse
/// call inherits MainActor isolation statically — direct
/// non-Sendable `AppState` access, no shim, no `assumeIsolated`.
///
/// Named `UICore` (vs. `MainActorCore`) so the symmetry with `TestCore`
/// is by *domain* (UI vs. tests) rather than implementation mechanism.
// SKIP @bridgeMembers
@MainActor
public struct UICore {
    public let state: AppState
    public let commands: AsyncStream<AppCommand>
    let handler: AppCore

    public init() {
        self.init(client: HNClient(), clock: ContinuousClock())
    }

    /// Test seam — not bridged.
    init(
        client: HNClient,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        let state = AppState()
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.state = state
        self.commands = stream
        self.handler = AppCore(
            state: state,
            commands: stream,
            commandsContinuation: continuation,
            client: client,
            clock: clock
        )
        handler.bootstrap()
    }

    /// Single entry point for every user-driven mutation.
    public func dispatch(_ event: AppEvent) async {
        await handler.dispatch(event)
    }

    /// Test-only teardown — production `UICore` is app-lifetime.
    public func shutdown() {
        handler.shutdown()
    }
}
