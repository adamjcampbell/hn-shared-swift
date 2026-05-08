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
/// **Lifecycle.** [attach] is once-and-only-once: a `precondition`
/// traps if it's called while already attached. Production calls it
/// exactly once (`AppCoreApplication.onCreate` → `AppModelHolder.start()`
/// → `appcoreCreate`); tests cycle by pairing each `appcoreCreate(...)`
/// with a `finally { appcoreDestroy() }` (or a `@Before` reset hook —
/// see `BridgePerfTest`). [detach] is the symmetric teardown that the
/// `appcoreDestroy` JNI thunk calls — idempotent so a double-detach
/// from a `finally` after a thrown setup is benign.
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

    private static var snapshotPump: AndroidSnapshot<AppState>!
    private static var commandPump: AndroidCommands<AppCommand>!
    private static var searchQueryBinding: AndroidBinding<AppState, String>!
    private static var isLoadingBinding: AndroidBinding<AppState, Bool>!
    private static var queryWatcherTask: Task<Void, Never>!

    /// Wire up all three sinks and start the pumps + watcher.
    ///
    /// **Once-and-only-once contract.** Production calls [attach]
    /// exactly once at app startup (`AppCoreApplication.onCreate` →
    /// `AppModelHolder.start()` → `appcoreCreate`). The precondition
    /// catches accidental double-attach loudly. Tests are allowed to
    /// cycle by calling [detach] between cases — every attach is
    /// preceded by a prior detach, so the precondition holds.
    static func attach(
        snapshotSink: any SnapshotSink,
        commandSink: any CommandSink,
        searchQuerySink: any SearchQuerySink,
        isLoadingSink: any IsLoadingSink
    ) {
        precondition(snapshotPump == nil, "Bridge.attach called while already attached")

        snapshotPump = AndroidSnapshot(source: { appModel.state }, sink: snapshotSink)
        snapshotPump.start()

        commandPump = AndroidCommands(stream: appModel.commands, sink: commandSink)
        commandPump.start()

        searchQueryBinding = AndroidBinding(
            root: appModel.state,
            keyPath: \.searchQuery,
            deliver: searchQuerySink.deliverSearchQuery(value:)
        )
        searchQueryBinding.start()

        isLoadingBinding = AndroidBinding(
            root: appModel.state,
            keyPath: \.isLoading,
            deliver: isLoadingSink.deliverIsLoading(value:)
        )
        isLoadingBinding.start()

        queryWatcherTask = Task {
            await appModel.runSearchQueryWatcher()
        }
    }

    /// Idempotent teardown. Leaves `appModel` and its `commands` stream
    /// untouched so a subsequent [attach] picks up where we left off
    /// (one model per process; sinks change, the model doesn't). Used
    /// by tests between cases — production never calls this.
    static func detach() {
        snapshotPump?.stop(); snapshotPump = nil
        commandPump?.stop(); commandPump = nil
        searchQueryBinding?.stop(); searchQueryBinding = nil
        isLoadingBinding?.stop(); isLoadingBinding = nil
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
    static func enqueueAwaitableDispatch(_ event: AppEvent, completion: some AndroidCompletion) {
        Task {
            await dispatch(event)
            completion.complete()
        }
    }

    /// Per-property setter for `state.searchQuery`. Compose calls this
    /// on every keystroke through the JNI thunk; the binding records
    /// the value for echo dedup before applying the write. Traps
    /// loudly if called before [attach].
    static func handleSetSearchQuery(_ value: String) {
        searchQueryBinding.set(value)
    }

    /// Per-property getter. Compose's `BridgedSource` reads through
    /// this on each composition for `produceState(initialValue:)`'s
    /// cold-start seed. Traps loudly if called before [attach].
    static func getSearchQuery() -> String {
        searchQueryBinding.get()
    }

    /// Per-property setter for `state.isLoading`. Functionally unused
    /// today — `isLoading` is a one-way Swift→Kotlin signal owned by
    /// `runFetch` — but kept for parity with the `searchQuery` shape so
    /// `AndroidBinding`'s two-way contract holds and `BridgedSource`'s
    /// `writeThrough` has a real entry point. Traps loudly if called
    /// before [attach].
    static func handleSetIsLoading(_ value: Bool) {
        isLoadingBinding.set(value)
    }

    /// Per-property getter for `state.isLoading`. Used by Compose's
    /// `BridgedSource` for the cold-start seed before the first
    /// observation lands. Traps loudly if called before [attach].
    static func getIsLoading() -> Bool {
        isLoadingBinding.get()
    }
}
#endif
