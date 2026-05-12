import Foundation
import Observation

/// Bridge shell around `AppEventHandler`. Owns `AppState` and re-exposes
/// the handler's `commands` stream so iOS and Android see one type for
/// state + dispatch + commands. All orchestration lives on the handler.
///
/// Bridged to Kotlin via SkipFuse — see the `// SKIP @bridge` markers
/// below. The handler itself is not bridged; Kotlin only sees the
/// shrunken public surface here.
// SKIP @bridge
public final class AppModel {
    // SKIP @bridge
    public let state = AppState()

    /// Read end of the handler's commands stream. iOS subscribes with
    /// `for await` from a long-lived `.task`. On Android, Compose
    /// converts to `Flow` via SkipFuse's `KotlinConverting`.
    // SKIP @bridge
    public let commands: AsyncStream<AppCommand>

    let handler: AppEventHandler

    // SKIP @bridge
    public init() {
        let h = AppEventHandler(state: state, client: HNClient(), clock: ContinuousClock())
        self.handler = h
        self.commands = h.commands
    }

    /// Test seam — not bridged. `client` and `clock` types don't bridge
    /// (closure-bag struct, existential `Clock`).
    init(
        client: HNClient,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        let h = AppEventHandler(state: state, client: client, clock: clock)
        self.handler = h
        self.commands = h.commands
    }

    /// Single entry point for every user-driven mutation. Forwards to
    /// `AppEventHandler.handle(_:)`.
    // SKIP @bridge
    public func dispatch(_ event: AppEvent) async {
        await handler.handle(event)
    }

    /// Long-lived background pipeline (search-query → fetch → commit).
    /// The host `await`s this from `RootView`'s `.task` on iOS or
    /// `LaunchedEffect` on Android. Cancellation propagates from the
    /// host's surrounding Task. Forwards to `AppEventHandler.run()`.
    // SKIP @bridge
    public func run() async {
        await handler.run()
    }
}
