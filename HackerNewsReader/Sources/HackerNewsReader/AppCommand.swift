import Foundation

/// One-shot imperative messages sent from `AppEngine` to the UI —
/// the symmetric counterpart to ``AppEvent``. Models presentations
/// owned by the platform (a Safari sheet on iOS, a Chrome Custom Tab
/// on Android) whose lifetime doesn't belong in ``AppState``.
///
/// Delivered through ``AppCore/commands``. iOS consumes it with
/// `for await` from a long-lived `.task`; Android collects via
/// `core.commands.kotlin().collect { ... }` (SkipFuse bridges
/// `AsyncStream<T>` to `Flow<T>`).
// SKIP @bridge
public enum AppCommand: Sendable, Equatable {
    case presentURL(value: String)
}
