import Foundation

/// One-shot imperative messages sent from ``Engine`` to the UI —
/// the outbound half of the Elm-shaped pair (``Message`` is inbound).
/// Models presentations owned by the platform (a Safari sheet on
/// iOS, a Chrome Custom Tab on Android) whose lifetime doesn't
/// belong in ``Model``.
///
/// Delivered through ``Core/commands``. iOS consumes it with
/// `for await` from a long-lived `.task`; Android collects via
/// `core.commands.kotlin().collect { ... }` (SkipFuse bridges
/// `AsyncStream<T>` to `Flow<T>`).
// SKIP @bridge
public enum Command: Sendable, Equatable {
    case presentURL(value: String)
}
