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
        let appCore = AppCore(
            state: state,
            commands: stream,
            commandsContinuation: continuation,
            client: Client(),
            clock: ContinuousClock(),
            now: Date.init
        )
        self.appCore = appCore
        // Install the hop-to-host closure. The closure literal is
        // created in this `@MainActor` init body, so
        // `@_inheritActorContext` (on `setMutate`) captures
        // `@MainActor` as the closure's static isolation, and
        // `@isolated(any)` carries that as the runtime hop target.
        // The sync call to `applyMutation` is what forces the
        // actor-isolation inference.
        appCore.setMutate { body in
            applyOnMainActor(body)
        }
    }

    /// Single entry point for every user-driven mutation.
    public func sendEvent(_ event: AppEvent) async {
        await appCore.sendEvent(event)
    }
}

/// Free `@MainActor` function used by `UICore.init` as the sync call
/// inside the `mutate` closure body. The sync call to a `@MainActor`
/// function forces the closure to be `@MainActor`-isolated, which
/// `@_inheritActorContext` on `AppCore.setMutate` then captures into
/// `@isolated(any)`'s runtime token. A free function (instead of a
/// method on `UICore`) avoids the "escaping closure captures
/// mutating self" error a struct hits in its init.
@MainActor
private func applyOnMainActor(_ body: () -> Void) {
    body()
}
