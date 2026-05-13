import Foundation
import Observation

/// Production bridge wrapper. `@MainActor`-pinned, Skip-bridged via
/// `// SKIP @bridgeMembers`. Owns `AppState` and the commands stream;
/// delegates orchestration to an internal `AppCoreActor`.
///
/// Naming mirrors Point-Free's CA 2.0 `Store` / `StoreActor` split,
/// although in this codebase `AppCoreActor` is currently a `@MainActor`
/// class rather than a true `actor` — see the doc on `AppCoreActor`
/// for the region-isolation reason. The split keeps the bridged
/// surface (`AppCore`) thin and stable for Skip while orchestration
/// lives in the internal type.
// SKIP @bridgeMembers
@MainActor
public final class AppCore {
    public let state: AppState

    /// Read end of the commands stream. iOS subscribes with `for await`
    /// from a long-lived `.task`. On Android, Compose converts to
    /// `Flow` via SkipFuse's `KotlinConverting`.
    public let commands: AsyncStream<AppCommand>

    let handler: AppCoreActor

    public init() {
        let handler = AppCoreActor()
        self.handler = handler
        self.state = handler.state
        self.commands = handler.commands
    }

    /// Test seam — not bridged. `client` and `clock` types don't bridge
    /// (closure-bag struct, existential `Clock`).
    init(
        client: HNClient,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        let handler = AppCoreActor(client: client, clock: clock)
        self.handler = handler
        self.state = handler.state
        self.commands = handler.commands
    }

    /// Single entry point for every user-driven mutation.
    public func dispatch(_ event: AppEvent) async {
        await handler.dispatch(event)
    }

    /// Long-lived background pipeline. The host `await`s this from
    /// `RootView`'s `.task` on iOS or `LaunchedEffect` on Android;
    /// cancellation propagates from the host's surrounding Task.
    public func run() async {
        await handler.run()
    }
}
