import Foundation
import Observation

/// `@MainActor` UI-facing shell. Bridged to Kotlin via Skip; SwiftUI
/// and Compose both consume this type. Owns `AppState` and the
/// commands stream; the non-Sendable `AppCore` workhorse it holds
/// inherits MainActor isolation from this struct's calls.
// SKIP @bridgeMembers
@MainActor
public struct UICore {
    public let state: AppState
    public let commands: AsyncStream<AppCommand>
    let appCore: AppCore

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
        self.appCore = AppCore(
            state: state,
            commands: stream,
            commandsContinuation: continuation,
            client: client,
            clock: clock
        )
    }

    /// Single entry point for every user-driven mutation.
    public func dispatch(_ event: AppEvent) async {
        await appCore.dispatch(event)
    }

    /// Test-only teardown — production `UICore` is app-lifetime.
    public func shutdown() {
        appCore.shutdown()
    }
}
