import Foundation

/// User-driven mutations dispatched to `AppEngine`.
///
/// Both platforms route through the ``SendAppEvent`` returned inside
/// ``AppCore``: iOS reads it via `@Environment(\.sendEvent)` and
/// calls `sendEvent(.toggleRead(id:))`; Android holds the handle on
/// `Application` and calls `core.sendEvent.send(...)`.
// SKIP @bridge
public enum AppEvent: Sendable, Equatable {
    case toggleRead(id: String)
    case openStory(id: String)
    case refresh
    case loadMore
}
