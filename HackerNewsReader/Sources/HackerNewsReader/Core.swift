import Foundation
import Observation
import HackerNews

/// The surfaces the UI consumes — observable state, a one-shot
/// command stream, and an `Equatable` send-message capability.
// SKIP @bridgeMembers
@MainActor
public struct Core {
    public let state: Model
    public let commands: AsyncStream<Command>
    public let sendMessage: SendMessageAction
}

/// Builds the ``Engine`` and returns the ``Core`` handle for the UI
/// to consume.
///
/// Call once at app scope — iOS holds it as `@State` on the `App`,
/// Android stashes it on `Application` in `onCreate` — and keep the
/// handle for the process lifetime.
///
/// - Returns: A handle bundling state, the command stream, and the
///   send-message capability.
// SKIP @bridge
@MainActor public func makeCore() -> Core {
    // Safe: Engine borrows MainActor's executor and Core is
    // @MainActor, so Model only ever lives on MainActor. Unchecked is
    // the local opt-out from `assumeIsolated`'s Sendable-return check.
    struct Unchecked<Value>: @unchecked Sendable {
        let value: Value; init(_ value: Value) { self.value = value }
    }

    let engine = Engine(isolation: MainActor.shared)
    engine.assumeIsolated { $0.bind() }

    var model: Model { engine.assumeIsolated { Unchecked($0.state) }.value }

    return Core(
        state: model,
        commands: engine.commands,
        sendMessage: SendMessageAction(engine)
    )
}
