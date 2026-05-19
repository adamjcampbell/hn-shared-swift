import Foundation
import Observation
import HackerNews

/// Handle returned by `makeAppCore()` — bundles the three surfaces
/// the UI consumes: observable state, a one-shot command stream, and
/// an Equatable send-event capability.
// SKIP @bridgeMembers
@MainActor
public struct AppCoreHandle {
    public let state: AppState
    public let commands: AsyncStream<AppCommand>
    public let sendEvent: SendAppEvent
}

/// Builds the `AppCore` and returns the handle. Call once at app
/// scope (iOS: `@State` on the `App`; Android: `Application.onCreate`)
/// and hold the handle for the process lifetime — the `AppCore`
/// inside survives Activity recreation. `AppCore` borrows MainActor's
/// executor via SE-0392 so event handling and observation callbacks
/// run in MainActor's isolation region — the same region SwiftUI and
/// Compose recompose on.
// SKIP @bridge
@MainActor public func makeAppCore() -> AppCoreHandle {
    // nonisolated(unsafe) lets the non-Sendable AppState cross
    // into AppCore's nonisolated init. Sound because both ends sit
    // in MainActor's region (AppCore borrows MainActor's executor;
    // AppCoreHandle is @MainActor) — SE-0414.
    nonisolated(unsafe) let state = AppState()
    let appCore = AppCore(
        state: state,
        client: Client(),
        clock: ContinuousClock(),
        isolation: MainActor.shared
    )
    return AppCoreHandle(
        state: state,
        commands: appCore.commands,
        sendEvent: SendAppEvent(appCore)
    )
}
