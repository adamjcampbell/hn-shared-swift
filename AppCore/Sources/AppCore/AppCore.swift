import Foundation
import Observation

/// PROTOTYPE: `@MainActor`-pinned shell. `AppCoreActor` is now a
/// non-Sendable class whose methods inherit MainActor isolation via
/// `isolation: isolated (any Actor)? = #isolation`. No StateAccess
/// shim, no `assumeIsolated`, no borrowed executor.
// SKIP @bridgeMembers
@MainActor
public struct AppCore {
    public let state: AppState
    public let commands: AsyncStream<AppCommand>
    let handler: AppCoreActor

    public init() {
        self.init(client: HNClient(), clock: ContinuousClock())
    }

    init(
        client: HNClient,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        let state = AppState()
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.state = state
        self.commands = stream
        self.handler = AppCoreActor(
            state: state,
            commands: stream,
            commandsContinuation: continuation,
            client: client,
            clock: clock
        )
        // Direct call — inherits MainActor isolation.
        handler.bootstrap()
    }

    public func dispatch(_ event: AppEvent) async {
        await handler.dispatch(event)
    }

    public func shutdown() async {
        handler.shutdown()
    }
}
