import Foundation

/// User-driven inputs the core applies to ``Model`` — the inbound
/// half of the Elm-shaped pair (``Command`` is outbound). Named for
/// Elm's `Msg`, expanded to a full word.
///
/// Both platforms build a ``SendMessageAction`` from the ``Core``
/// (`SendMessageAction(core)`): iOS installs it via
/// `@Environment(\.sendMessage)` and calls `sendMessage(.toggleRead(id:))`;
/// Android holds the `Core` on `Application` and calls
/// `sendMessage.send(...)`.
// SKIP @bridge
public enum Message: Sendable, Equatable {
    case toggleRead(id: String)
    case openStory(id: String)
    case refresh
    case loadMore
}
