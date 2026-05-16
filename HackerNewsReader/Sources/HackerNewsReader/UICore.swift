import Foundation
import Observation
import HackerNews

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
        let state = AppState()
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.state = state
        self.commands = stream
        self.appCore = AppCore(
            state: state,
            commands: stream,
            commandsContinuation: continuation,
            client: Client(),
            clock: ContinuousClock(),
            now: Date.init,
            borrowing: MainActor.shared
        )
    }

    /// Single entry point for every user-driven mutation.
    public func sendEvent(_ event: AppEvent) async {
        await appCore.sendEvent(event)
    }
}
