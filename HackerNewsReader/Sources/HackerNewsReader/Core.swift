import Foundation
import Observation
import HackerNews

/// Module-level singletons that form the cross-platform core's public
/// surface. `appState` and `appCore` are isolated to MainActor:
/// `appCore` borrows MainActor's executor via SE-0392 so all event
/// handling and emitted observation callbacks run in MainActor's
/// isolation region. SwiftUI and Compose both consume these
/// directly; `// SKIP @bridge` markers expose the free functions to
/// Kotlin alongside the bridged `appState` and `commands`.

@MainActor private let _commandStream = AsyncStream<AppCommand>.makeStream()

// SKIP @bridge
@MainActor public let appState = AppState()

// SKIP @bridge
@MainActor public let commands: AsyncStream<AppCommand> = _commandStream.stream

@MainActor private let appCore: AppCore = _makeAppCore()

@MainActor private func _makeAppCore() -> AppCore {
    // Transient nonisolated(unsafe) rebind lets the non-Sendable
    // AppState reach AppCore: both references stay in the same
    // isolation region (SE-0414), so the rebinding is sound.
    nonisolated(unsafe) let unsafeAppState = appState
    return AppCore(
        state: unsafeAppState,
        commandsContinuation: _commandStream.continuation,
        client: Client(),
        clock: ContinuousClock(),
        isolation: MainActor.shared
    )
}

/// Fire-and-forget mutation. Returns after the dispatch hop into
/// `appCore`; the event handler runs to completion on its own Task.
// SKIP @bridge
@MainActor public func sendEvent(_ event: AppEvent) {
    Task { await appCore.sendEvent(event) }
}

/// Awaitable mutation. Suspends until the event handler completes —
/// use from `.refreshable` so the pull-to-refresh spinner stays
/// visible until the fetch lands.
// SKIP @bridge
@MainActor public func sendEventAsync(_ event: AppEvent) async {
    await appCore.sendEvent(event)
}
