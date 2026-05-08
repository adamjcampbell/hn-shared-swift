import Foundation
import AppCore

// MARK: - jextract entry points
//
// These public functions are scanned by `swift-java jextract --mode=jni`
// (configured via `swift-java.config` in this directory; the
// `JExtractSwiftPlugin` SwiftPM plugin runs it as part of `swift build`).
// jextract generates a Java class `com.example.appcore.bridge.AppCoreAndroid`
// — named after the Swift module — with matching `native` static methods,
// plus a Swift `@_cdecl` glue file. We never write the JNI naming or
// marshalling by hand. Note: `native` is a Java reserved keyword, so the
// Java package is `…bridge` rather than `…native`.
//
// There is one `AppModel` per process, owned by `AndroidBridge.shared`, so
// none of these entry points take a handle. Command-shaped mutations are
// funnelled through `appcoreDispatch(eventJSON:)` that decodes a Codable
// `AppEvent`. Continuously-bound primitives (currently `searchQuery`) get
// dedicated per-property setters and matching push sinks; adding a new
// mutation case in `AppCore` covers both shapes.
//
// **Sync entry via `assumeIsolated`.** `AndroidBridge`'s custom executor
// (`LooperExecutor`) pins it to Android's main `Looper`. Compose always
// calls these thunks from the UI thread, which *is* the bridge actor's
// executor, so `Actor.assumeIsolated` (SE-0392 + Swift 6) lets the thunks
// enter the actor synchronously without `Task { await … }` allocation.
// `enqueueDispatch` is the sync, fire-and-forget cousin of `dispatch(_:)`
// (mirroring the iOS `AppEventDispatch.callAsFunction(_:)` / `run(_:)`
// split) for the case where the model method itself is `async`.
//
// **Contract.** Calling these thunks off the UI thread on Android, or
// at all on the macOS host, will trap inside `assumeIsolated`. Compose
// only ever calls them from the UI thread; the macOS host build never
// invokes them (the JNI runtime isn't present). On macOS the bodies
// are `#if canImport(Android)`-gated to no-ops so jextract still sees
// the public-API signatures. See AGENT.md.

public func appcoreCreate(
    snapshotSink: some SnapshotSink,
    commandSink: some CommandSink,
    searchQuerySink: some SearchQuerySink
) {
    // `Observations` (Swift 6.2+) emits an initial value as well as all
    // future ones (see WWDC25 *What's new in Swift*), so the bridge
    // actor's `attach()` already delivers a cold-start snapshot ~1–2 ms
    // after this call returns. `BridgePerfTest.a_coldStart_…` is the
    // regression guard. Compose reads `AppModelHolder.state` as a
    // nullable `AppState?`, so the brief window before that emission
    // lands renders the same empty-state UI as the initial snapshot
    // would have. The `searchQuerySink` similarly emits the cold-start
    // value of `state.searchQuery` (initially `""`) within the same
    // window.
    #if canImport(Android)
    AndroidBridge.shared.assumeIsolated { bridge in
        bridge.attach(
            snapshotSink: snapshotSink,
            commandSink: commandSink,
            searchQuerySink: searchQuerySink
        )
    }
    #endif
}

public func appcoreDispatch(eventJSON: String) {
    guard let event: AppEvent = JNICoder.decode(from: eventJSON) else { return }
    #if canImport(Android)
    AndroidBridge.shared.assumeIsolated { $0.enqueueDispatch(event) }
    #endif
}

/// Awaitable cousin of `appcoreDispatch(eventJSON:)`. Mirrors iOS's
/// `AppEventDispatch.run(_:) async` — the awaitable side of the
/// sync/async dispatch duality. The Kotlin-side `suspendCancellableCoroutine`
/// wrapper passes a single-shot `DispatchCompletion`; this thunk hands
/// it to `enqueueAwaitableDispatch`, which spawns a Task that awaits the
/// model dispatch end-to-end and then fires `completion.complete()`.
///
/// Pull-to-refresh in Compose is the primary consumer: the awaiting
/// coroutine keeps the indicator visible for the full fetch lifetime,
/// no race with snapshot propagation. Decode failures complete
/// immediately so a malformed event doesn't strand a Kotlin coroutine.
public func appcoreDispatchAwait(eventJSON: String, completion: some DispatchCompletion) {
    guard let event: AppEvent = JNICoder.decode(from: eventJSON) else {
        completion.complete()
        return
    }
    #if canImport(Android)
    AndroidBridge.shared.assumeIsolated { $0.enqueueAwaitableDispatch(event, completion: completion) }
    #else
    completion.complete()
    #endif
}

/// Per-property setter for `state.searchQuery`. Compose calls this on
/// every keystroke. The bridge dedups echoes via `lastSetterValue` so
/// the value Compose just typed isn't pushed back through `SearchQuerySink`
/// to clobber the in-progress text.
public func appcoreSetSearchQuery(value: String) {
    #if canImport(Android)
    AndroidBridge.shared.assumeIsolated { $0.handleSetSearchQuery(value) }
    #endif
}

/// Per-property getter for `state.searchQuery`. Used by the Compose
/// `BridgedSource` wrapper as `produceState`'s initial value, so the
/// first composition reads the live Swift value (correct under future
/// process-death restoration) rather than a hardcoded `""`. Sync
/// because the thunk is on the UI thread and so is the bridge actor's
/// executor — `assumeIsolated` is just a property read.
public func appcoreGetSearchQuery() -> String {
    #if canImport(Android)
    return AndroidBridge.shared.assumeIsolated { $0.getSearchQuery() }
    #else
    return ""
    #endif
}

public func appcoreDestroy() {
    #if canImport(Android)
    AndroidBridge.shared.assumeIsolated { $0.detach() }
    #endif
}
