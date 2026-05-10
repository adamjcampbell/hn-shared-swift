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

    private static var commandPump: AndroidCommands!
    private static var queryWatcherTask: Task<Void, Never>!

    /// Outstanding cancellable Tasks, keyed by token. Used for both
    /// observation Tasks (`appcoreObserve*`) and awaitable dispatch
    /// Tasks (`appcoreRefreshAwait`). Any code that wants its Task
    /// cancellable from Kotlin registers it via [registerTask] and
    /// returns the token to Kotlin; Kotlin calls
    /// `appcoreCancelTask(token)` to cancel.
    ///
    /// [detach] cancels everything still in the registry — important
    /// for tests that `appcoreDestroy` without pairing each register
    /// with an explicit cancel, and a defensive sweep for any
    /// in-flight dispatch Tasks at app teardown.
    private static var tasks: [Int64: Task<Void, Never>] = [:]
    private static var nextTaskToken: Int64 = 1

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
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// Registers a Task in the cancellation registry and returns its
    /// token. Used by both observation registrations and awaitable
    /// dispatches.
    static func registerTask(_ task: Task<Void, Never>) -> Int64 {
        let token = nextTaskToken
        nextTaskToken += 1
        tasks[token] = task
        return token
    }

    /// Cancels the Task identified by [token] and removes it from the
    /// registry. No-op if [token] has already been cancelled or never
    /// existed (e.g. after `detach` swept the registry).
    static func cancelTask(_ token: Int64) {
        tasks.removeValue(forKey: token)?.cancel()
    }

    static func dispatch(_ event: AppEvent) async {
        await appModel.dispatch(event)
    }

    static func enqueueDispatch(_ event: AppEvent) {
        Task { await dispatch(event) }
    }

    /// Spawns a Task that awaits the dispatch end-to-end and fires
    /// `completion.complete()`. Registers the Task in the cancellation
    /// registry and returns its token so Kotlin can cooperatively cancel
    /// the in-flight dispatch (e.g. when the awaiting coroutine is
    /// cancelled because its host scope was torn down).
    static func enqueueAwaitableDispatch(_ event: AppEvent, completion: some AndroidCompletion) -> Int64 {
        let task = Task {
            await dispatch(event)
            completion.complete()
        }
        return registerTask(task)
    }

    static func handleSetSearchQuery(_ value: String) {
        appModel.state.searchQuery = value
    }


}
#endif
