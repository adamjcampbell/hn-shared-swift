import Foundation
import Observation

/// Production bridge wrapper. `@MainActor`-pinned, Skip-bridged via
/// `// SKIP @bridgeMembers`. Owns `AppState` and the commands stream;
/// delegates all orchestration to an internal `AppCoreActor`. A
/// value-type facade — copying it shares the underlying `AppState`,
/// `AppCoreActor`, and stream-continuation references.
///
/// Naming mirrors Point-Free's CA 2.0 `Store` / `StoreActor` split.
/// `AppCoreActor` is a real `actor` whose executor is borrowed from
/// `MainActor.shared` via `unownedExecutor` (SE-0392) — so the actor
/// and this `@MainActor` struct share one physical executor at runtime.
///
/// `AppCoreActor` doesn't own `AppState`; it holds a `StateAccess`
/// shim (see `StateAccess.swift`) that this init installs post-
/// construction via `handler.assumeIsolated { handler.state = … }`.
/// The shim wraps a `MainActorMutator` which uses
/// `MainActor.assumeIsolated` to reach `appState` when
/// `AppCoreActor` invokes it. The shared executor makes the
/// assumeIsolated check a runtime no-op; the shim encodes the
/// proof of "same isolation region" that the type system needs to
/// mutate the non-`Sendable` `@Observable` `AppState` without any
/// `@unchecked Sendable` or `nonisolated(unsafe)` escapes.
// SKIP @bridgeMembers
@MainActor
public struct AppCore {
    public let state = AppState()

    /// Read end of the commands stream. iOS subscribes with `for await`
    /// from a long-lived `.task`. On Android, Compose converts to
    /// `Flow` via SkipFuse's `KotlinConverting`.
    public let commands: AsyncStream<AppCommand>

    let handler: AppCoreActor

    public init() {
        self.init(client: HNClient(), clock: ContinuousClock())
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

        let mutator = MainActorMutator(self.state)
        handler.assumeIsolated { handler in
            handler.bootstrap(state: StateAccess(mutator))
        }
    }

    /// Single entry point for every user-driven mutation.
    public func dispatch(_ event: AppEvent) async {
        await handler.dispatch(event)
    }

    /// Test-only teardown — production `AppCore` is app-lifetime.
    public func shutdown() async {
        await handler.shutdown()
    }
}
