import Foundation

/// One-shot imperative messages sent **from** `AppModel` **to** the UI —
/// the symmetric counterpart to `AppEvent`. Where `AppEvent` is the UI
/// asking the core to mutate state, `AppCommand` is the core asking the
/// UI to perform a presentation that is owned by the platform (a Safari
/// sheet on iOS, a Chrome Custom Tab on Android) and whose lifetime is
/// not state we want to model in `AppState`.
///
/// Delivered through `AppModel.commands: AsyncStream<AppCommand>`. iOS
/// consumes it with `for await` from a `.task` modifier on a long-lived
/// view. On Android, SkipFuse bridges `AsyncStream<T>` to
/// `kotlinx.coroutines.flow.Flow<T>` via `KotlinConverting`, so a
/// Composable can `appModel.commands.kotlin().collect { ... }`.
///
/// **Why not call this an `Effect`?** TCA-style architectures reserve
/// "Effect" for reducer-spawned async work that produces more actions,
/// and Compose reserves `LaunchedEffect`/`SideEffect` for composable
/// lifecycle scopes. "Command" is unambiguous, follows CQRS conventions
/// (a request to do something, with no return value), and leaves
/// "Effect" free if we later move to a fully fledged reducer model.
// SKIP @bridge
public enum AppCommand: Sendable, Equatable {
    case presentURL(value: String)
}
