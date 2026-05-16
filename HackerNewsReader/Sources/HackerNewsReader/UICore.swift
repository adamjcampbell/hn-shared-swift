import Foundation
import Observation
import HackerNews

/// `@MainActor` UI-facing shell. Bridged to Kotlin via Skip; SwiftUI
/// and Compose both consume this type. Owns `AppState` and the
/// commands stream; `AppCore` is an actor that borrows MainActor's
/// executor so its methods physically run on the same serial
/// executor as UICore's reads.
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
        // The single escape hatch: a transient local that lets us
        // share the `AppState` reference with AppCore (an actor)
        // without `@unchecked Sendable` on the type. After this
        // statement nothing else uses `nonisolated(unsafe)`.
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
        // Listener Task — created on MainActor, runs on AppCore's
        // (= MainActor's) executor. The await hop is a runtime no-op
        // because executors match.
        Task { await appCore.startListener() }
    }

    /// Single entry point for every user-driven mutation.
    public func sendEvent(_ event: AppEvent) async {
        await appCore.sendEvent(event)
    }
}
