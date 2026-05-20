import Foundation

/// User-driven inputs dispatched to ``Engine`` — the inbound half
/// of the Elm-shaped pair (``Command`` is outbound). Named for
/// Elm's `Msg`, expanded to a full word.
///
/// Both platforms route through the ``SendMessageAction`` returned
/// inside ``Core``: iOS reads it via `@Environment(\.sendMessage)`
/// and calls `sendMessage(.toggleRead(id:))`; Android holds the
/// handle on `Application` and calls `core.sendMessage.send(...)`.
// SKIP @bridge
public enum Message: Sendable, Equatable {
    case toggleRead(id: String)
    case openStory(id: String)
    case refresh
    case loadMore
}
