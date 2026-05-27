import Foundation
import Observation
import HackerNews

/// The surfaces the UI consumes: the observable `Model`, a one-shot
/// command stream, and an `Equatable` send-message capability.
// SKIP @bridgeMembers
@MainActor
public struct Core {
    public let model: Model
    public let commands: AsyncStream<Command>
    public let sendMessage: SendMessageAction
}

/// Builds the ``Engine`` and returns the ``Core`` handle for the UI
/// to consume.
///
/// Call once at app scope and keep the handle for the process
/// lifetime: iOS holds it as `@State` on the `App`, Android stashes
/// it on `Application` in `onCreate`.
///
/// - Returns: A handle bundling the model, the command stream, and
///   the send-message capability.
// SKIP @bridge
@MainActor public func makeCore() -> Core {
    // Engine borrows MainActor's executor, so Model stays in MainActor's
    // isolation region. assumeIsolated asserts that at runtime; the
    // nonisolated(unsafe) rebind then carries Model into this scope.
    let engine = Engine(isolation: MainActor.shared)
    nonisolated(unsafe) var model: Model!

    engine.assumeIsolated { engine in
        engine.bind()
        model = engine.model
    }

    return Core(
        model: model,
        commands: engine.commands,
        sendMessage: SendMessageAction(engine)
    )
}
