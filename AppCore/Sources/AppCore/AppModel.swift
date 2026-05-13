import Foundation
import Observation

/// Bridge shell around `AppEventHandler`. Owns `AppState` and re-exposes
/// the handler's `commands` stream so iOS and Android see one type for
/// state + dispatch + commands. All orchestration lives on the handler.
///
/// Bridged to Kotlin via SkipFuse — `// SKIP @bridgeMembers` on the
/// type bridges every public member. The handler itself is internal,
/// so Kotlin only sees the shrunken public surface here.
// SKIP @bridgeMembers
@MainActor
public final class AppModel {
    public let state = AppState()

    /// Read end of the handler's commands stream. iOS subscribes with
    /// `for await` from a long-lived `.task`. On Android, Compose
    /// converts to `Flow` via SkipFuse's `KotlinConverting`.
    public let commands: AsyncStream<AppCommand>

    let handler: AppEventHandler

    public init() {
        self.handler = AppEventHandler(state: state, client: HNClient(), clock: ContinuousClock())
        self.commands = handler.commands
    }

    /// Test seam — not bridged. `client` and `clock` types don't bridge
    /// (closure-bag struct, existential `Clock`).
    init(
        client: HNClient,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.handler = AppEventHandler(state: state, client: client, clock: clock)
        self.commands = handler.commands
    }

    /// Single entry point for every user-driven mutation. Forwards to
    /// `AppEventHandler.handle(_:)`.
    public func dispatch(_ event: AppEvent) async {
        await handler.handle(event)
    }

    /// Long-lived background pipeline (search-query → fetch → commit).
    /// The host `await`s this from `RootView`'s `.task` on iOS or
    /// `LaunchedEffect` on Android. Cancellation propagates from the
    /// host's surrounding Task. Forwards to `AppEventHandler.run()`.
    public func run() async {
        await handler.run()
    }
}
