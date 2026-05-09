#if canImport(Android)
import Foundation
import AppCore

/// Android-side bridge namespace. State lives in `@JavaUIActor`-isolated
/// `static var`s; JNI thunks reach in via
/// `JavaUIActor.assumeIsolated { Bridge.foo() }`.
///
/// **Why an enum, not a class.** A namespace enum + `static var`s gives
/// us global-actor-isolated module state without an instance to manage.
/// Top-level `@JavaUIActor private var` is rejected by the compiler
/// ("top-level code variables cannot have a global actor") — the type
/// wrapping is the structural cost of getting global-actor isolation
/// for what would otherwise be file-private globals.
///
/// **Lifecycle.** [attach] is once-and-only-once: a `precondition`
/// traps if it's called while already attached. Production calls it
/// exactly once (`AppCoreApplication.onCreate` → `AppModelHolder.start()`
/// → `appcoreCreate`); tests cycle by pairing each `appcoreCreate(...)`
/// with a `finally { appcoreDestroy() }`.
@JavaUIActor
enum Bridge {
    /// One `AppModel` per process. Initialized lazily on first access
    /// from `@JavaUIActor` context (i.e., from a JNI thunk via
    /// `JavaUIActor.assumeIsolated { ... }`).
    static let appModel = AppModel()

    private static var commandPump: AndroidCommands<AppCommand>!
    private static var queryWatcherTask: Task<Void, Never>!

    static func attach(commandSink: any CommandSink) {
        precondition(commandPump == nil, "Bridge.attach called while already attached")

        commandPump = AndroidCommands(stream: appModel.commands, sink: commandSink)
        commandPump.start()

        queryWatcherTask = Task { await appModel.runSearchQueryWatcher() }
    }

    /// Idempotent teardown. Leaves `appModel` untouched so a subsequent
    /// [attach] picks up where we left off. Used by tests between cases.
    static func detach() {
        commandPump?.stop(); commandPump = nil
        queryWatcherTask?.cancel(); queryWatcherTask = nil
    }

    static func dispatch(_ event: AppEvent) async {
        await appModel.dispatch(event)
    }

    static func enqueueDispatch(_ event: AppEvent) {
        Task { await dispatch(event) }
    }

    static func enqueueAwaitableDispatch(_ event: AppEvent, completion: some AndroidCompletion) {
        Task {
            await dispatch(event)
            completion.complete()
        }
    }

    static func handleSetSearchQuery(_ value: String) {
        appModel.state.searchQuery = value
    }


}
#endif
