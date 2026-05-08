#if canImport(Android)
import Foundation
import AppCore

/// Android-side bridge namespace. Replaces the singleton
/// `actor AndroidBridge` from before Phase C: state lives in
/// `@JavaUIActor`-isolated `static var`s composed from the
/// `AndroidSnapshot` / `AndroidCommands` / `AndroidBinding` primitives,
/// and JNI thunks reach in via `JavaUIActor.assumeIsolated { Bridge.foo() }`.
///
/// **Why an enum, not a class.** A namespace enum + `static var`s gives
/// us global-actor-isolated module state without an instance to manage.
/// Top-level `@JavaUIActor private var` is rejected by the compiler
/// ("top-level code variables cannot have a global actor") — the type
/// wrapping is the structural cost of getting global-actor isolation
/// for what would otherwise be file-private globals.
///
/// **Lifecycle.** [attach] is idempotent: a re-attach cancels the prior
/// pumps and replaces the sinks (which is what tests need to do between
/// cases without a dedicated reset hook). [detach] is the symmetric
/// teardown that the `appcoreDestroy` JNI thunk calls.
///
/// **Cross-platform parity.** The `runSearchQueryWatcher` Task mirrors
/// iOS's `RootView`'s `.task { await appModel.runSearchQueryWatcher() }`
/// — the side-effect plumbing that gives `searchQuery` its
/// `@Binding`-like reactive shape. There's no actor-method wrapper
/// indirection here (as there was in the previous `AndroidBridge`
/// actor) because `Bridge.attach` is itself `@JavaUIActor`-isolated:
/// the watcher Task captures only the static `appModel`, and
/// `runSearchQueryWatcher()` is async nonisolated under SE-0461 so it
/// runs on the caller's (`@JavaUIActor`'s) executor.
@JavaUIActor
enum Bridge {
    /// One `AppModel` per process. Initialized lazily on first access
    /// from `@JavaUIActor` context (i.e., from a JNI thunk via
    /// `JavaUIActor.assumeIsolated { ... }`). Non-`Sendable` reads are
    /// fine because all accesses stay inside `@JavaUIActor` isolation.
    static let appModel = AppModel()

    private static var snapshotPump: AndroidSnapshot<AppState>?
    private static var commandPump: AndroidCommands<AppCommand>?
    private static var searchQueryBinding: AndroidBinding<String>?
    private static var queryWatcherTask: Task<Void, Never>?

    /// Wire up all three sinks and start the pumps + watcher. Idempotent.
    static func attach(
        snapshotSink: any SnapshotSink,
        commandSink: any CommandSink,
        searchQuerySink: any SearchQuerySink
    ) {
        detach()

        snapshotPump = AndroidSnapshot(source: { appModel.state }, sink: snapshotSink)
        snapshotPump?.start()

        commandPump = AndroidCommands(stream: appModel.commands, sink: commandSink)
        commandPump?.start()

        searchQueryBinding = AndroidBinding(
            read: { appModel.state.searchQuery },
            write: { appModel.state.searchQuery = $0 },
            deliver: { searchQuerySink.deliverSearchQuery(value: $0) }
        )
        searchQueryBinding?.start()

        queryWatcherTask = Task {
            await appModel.runSearchQueryWatcher()
        }
    }

    /// Idempotent teardown. Leaves `appModel` and its `commands` stream
    /// untouched so a subsequent [attach] picks up where we left off
    /// (one model per process; sinks change, the model doesn't).
    static func detach() {
        snapshotPump?.stop(); snapshotPump = nil
        commandPump?.stop(); commandPump = nil
        searchQueryBinding?.stop(); searchQueryBinding = nil
        queryWatcherTask?.cancel(); queryWatcherTask = nil
    }

    /// Async dispatch. Async-callable from `@JavaUIActor` context;
    /// mirrors iOS's `AppEventDispatch.run(_:) async`. The sync entry
    /// points below funnel through this so adding new dispatch shapes
    /// (e.g. with-result variants later) only edits one body.
    static func dispatch(_ event: AppEvent) async {
        await appModel.dispatch(event)
    }

    /// Sync, fire-and-forget dispatch. JNI thunks (`appcoreDispatch`)
    /// reach this via `JavaUIActor.assumeIsolated { … }`. Mirrors iOS's
    /// `AppEventDispatch.callAsFunction(_:)`.
    static func enqueueDispatch(_ event: AppEvent) {
        Task { await dispatch(event) }
    }

    /// Sync, awaitable-on-the-Kotlin-side dispatch. The completion
    /// callback fires when the Swift dispatch resolves; the Kotlin
    /// `suspendCancellableCoroutine` wrapper resumes its continuation
    /// then. Mirrors iOS's `.refreshable { await dispatch.run(.refresh) }`.
    static func enqueueAwaitableDispatch(_ event: AppEvent, completion: some DispatchCompletion) {
        Task {
            await dispatch(event)
            completion.complete()
        }
    }

    /// Per-property setter for `state.searchQuery`. Compose calls this
    /// on every keystroke through the JNI thunk; the binding records
    /// the value for echo dedup before applying the write.
    static func handleSetSearchQuery(_ value: String) {
        searchQueryBinding?.set(value)
    }

    /// Per-property getter. Compose's `BridgedSource` reads through
    /// this on each composition for `produceState(initialValue:)`'s
    /// cold-start seed. Returns "" before [attach] runs (the JNI
    /// thunk shouldn't be called pre-attach, but the empty default
    /// keeps the contract total).
    static func getSearchQuery() -> String {
        searchQueryBinding?.get() ?? ""
    }
}
#endif
