import Foundation
import MetaCodable

/// One-shot imperative messages sent **from** `AppModel` **to** the UI —
/// the symmetric counterpart to `AppEvent`. Where `AppEvent` is the UI
/// asking the core to mutate state, `AppCommand` is the core asking the
/// UI to perform a presentation that is owned by the platform (a Safari
/// sheet on iOS, a Chrome Custom Tab on Android) and whose lifetime is
/// not state we want to model in `AppState`.
///
/// Delivered through `AppModel.commands: AsyncStream<AppCommand>`. iOS
/// consumes it with `for await` from a `.task` modifier on a long-lived
/// view; Android's `Bridge.commandPump` (an `AndroidCommands<AppCommand>`)
/// consumes it and forwards each command over JNI as JSON to a `CommandSink`.
///
/// **Why not call this an `Effect`?** TCA-style architectures reserve
/// "Effect" for reducer-spawned async work that produces more actions,
/// and Compose reserves `LaunchedEffect`/`SideEffect` for composable
/// lifecycle scopes. "Command" is unambiguous, follows CQRS conventions
/// (a request to do something, with no return value), and leaves
/// "Effect" free if we later move to a fully fledged reducer model.
///
/// **Wire format:** identical conventions to `AppEvent` — a `type`
/// discriminator plus inline payload fields:
///
/// ```json
/// {"type":"presentURL","value":"https://example.com"}
/// ```
@Codable
@CodedAt("type")
public enum AppCommand: Sendable, Equatable {
    case presentURL(value: String)
}
