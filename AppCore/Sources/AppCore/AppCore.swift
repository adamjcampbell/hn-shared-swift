import Foundation
import Observation

/// Production bridge wrapper. `@MainActor`-pinned, Skip-bridged via
/// `// SKIP @bridgeMembers`. Owns `AppState` and the commands stream;
/// delegates all orchestration to an internal `AppCoreActor`.
///
/// Naming mirrors Point-Free's CA 2.0 `Store` / `StoreActor` split.
/// `AppCoreActor` is a real `actor` whose executor is borrowed from
/// `MainActor.shared` via `unownedExecutor` (SE-0392) — so the actor
/// and this `@MainActor` class share one physical executor at runtime.
///
/// State mutations flow back from `AppCoreActor` into `AppState`
/// through the `acquireState` closure that this init installs via
/// `handler.assumeIsolated { ... }`. The closure body captures
/// `self` (this `AppCore`) and uses `MainActor.assumeIsolated` to
/// reach `self.state` on MainActor when `AppCoreActor` invokes it.
/// The shared executor makes the assumeIsolated check a runtime
/// no-op; the closure encodes the proof of "same isolation region"
/// that the type system needs to mutate the non-`Sendable`
/// `@Observable` `AppState`.
// SKIP @bridgeMembers
@MainActor
public final class AppCore {
    public let state = AppState()

    /// Read end of the commands stream. iOS subscribes with `for await`
    /// from a long-lived `.task`. On Android, Compose converts to
    /// `Flow` via SkipFuse's `KotlinConverting`.
    public let commands: AsyncStream<AppCommand>

    let handler: AppCoreActor

    public init() {
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.commands = stream
        let handler = AppCoreActor(
            isolation: MainActor.shared,
            commands: stream,
            commandsContinuation: continuation
        )
        self.handler = handler

        handler.assumeIsolated { handler in
            handler.acquireState = { mutation in
                MainActor.assumeIsolated {
                    mutation(self.state)
                }
            }
        }
    }

    /// Test seam — not bridged. `client` and `clock` types don't bridge
    /// (closure-bag struct, existential `Clock`).
    init(
        client: HNClient,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.commands = stream
        let handler = AppCoreActor(
            isolation: MainActor.shared,
            commands: stream,
            commandsContinuation: continuation,
            client: client,
            clock: clock
        )
        self.handler = handler

        handler.assumeIsolated { handler in
            handler.acquireState = { mutation in
                MainActor.assumeIsolated {
                    mutation(self.state)
                }
            }
        }
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
