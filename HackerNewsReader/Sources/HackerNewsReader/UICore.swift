import Foundation
import Observation
import HackerNews

/// `@MainActor` UI-facing shell. Bridged to Kotlin via Skip; SwiftUI
/// and Compose both consume this type. Owns `AppState` and the
/// commands stream; `AppCore` borrows MainActor's executor so its
/// methods and Tasks share this serial queue.
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
        // The only `nonisolated(unsafe)` in the codebase. Lets the
        // non-Sendable `state` reference cross into `AppCore` (a
        // different actor type, same executor) without lying via
        // `@unchecked Sendable` on the AppState class itself.
        nonisolated(unsafe) let forAppCore = state
        let appCore = AppCore(
            state: forAppCore,
            commands: stream,
            commandsContinuation: continuation,
            client: Client(),
            clock: ContinuousClock(),
            now: Date.init,
            borrowing: MainActor.shared
        )
        self.appCore = appCore
        Task { await appCore.startListener() }
    }

    /// Single entry point for every user-driven mutation.
    public func sendEvent(_ event: AppEvent) async {
        await appCore.sendEvent(event)
    }
}
