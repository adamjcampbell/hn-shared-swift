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
// There is one `AppModel` per process, owned by the `@JavaUIActor`-isolated
// `Bridge` namespace, so none of these entry points take a handle.
// Command-shaped mutations are funnelled through `appcoreDispatch(eventJSON:)`
// that decodes a Codable `AppEvent`. Continuously-bound primitives
// (currently `searchQuery`) get dedicated per-property setters and
// matching push sinks; adding a new mutation case in `AppCore` covers
// both shapes.
//
// **Sync entry via `JavaUIActor.assumeIsolated`.** `JavaUIActor` is a
// global actor pinned to Android's main `Looper` via `LooperExecutor`.
// Compose always calls these thunks from the UI thread, which *is* the
// global actor's executor, so `JavaUIActor.assumeIsolated` lets the
// thunks enter the actor's isolation domain synchronously without
// `Task { await … }` allocation. `enqueueDispatch` is the sync,
// fire-and-forget cousin of `Bridge.dispatch(_:) async` (mirroring the
// iOS `AppEventDispatch.callAsFunction(_:)` / `run(_:)` split) for the
// case where the model method itself is `async`.
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
    // future ones (see WWDC25 *What's new in Swift*), so `Bridge.attach`
    // already delivers a cold-start snapshot ~1–2 ms after this call
    // returns. `BridgePerfTest.a_coldStart_…` is the regression guard.
    // Compose reads `AppModelHolder.state` as a nullable `AppState?`, so
    // the brief window before that emission lands renders the same
    // empty-state UI as the initial snapshot would have. The
    // `searchQuerySink` similarly emits the cold-start value of
    // `state.searchQuery` (initially `""`) within the same window.
    #if canImport(Android)
    JavaUIActor.assumeIsolated {
        Bridge.attach(
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
    JavaUIActor.assumeIsolated { Bridge.enqueueDispatch(event) }
    #endif
}

/// Awaitable cousin of `appcoreDispatch(eventJSON:)`. Mirrors iOS's
/// `AppEventDispatch.run(_:) async` — the awaitable side of the
/// sync/async dispatch duality. The Kotlin-side `awaitWithCompletion`
/// helper passes a single-shot `AndroidCompletion`; this thunk hands
/// it to `Bridge.enqueueAwaitableDispatch`, which spawns a Task that
/// awaits the model dispatch end-to-end and then fires
/// `completion.complete()`.
///
/// Pull-to-refresh in Compose is the primary consumer: the awaiting
/// coroutine keeps the indicator visible for the full fetch lifetime,
/// no race with snapshot propagation. Decode failures complete
/// immediately so a malformed event doesn't strand a Kotlin coroutine.
public func appcoreDispatchAwait(eventJSON: String, completion: some AndroidCompletion) {
    guard let event: AppEvent = JNICoder.decode(from: eventJSON) else {
        completion.complete()
        return
    }
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.enqueueAwaitableDispatch(event, completion: completion) }
    #else
    completion.complete()
    #endif
}

/// Per-property setter for `state.searchQuery`. Compose calls this on
/// every keystroke. The `AndroidBinding` dedups echoes via
/// `lastSetterValue` so the value Compose just typed isn't pushed back
/// through `SearchQuerySink` to clobber the in-progress text.
public func appcoreSetSearchQuery(value: String) {
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.handleSetSearchQuery(value) }
    #endif
}

/// Per-property getter for `state.searchQuery`. Used by the Compose
/// `BridgedSource` wrapper as `produceState`'s initial value, so the
/// first composition reads the live Swift value (correct under future
/// process-death restoration) rather than a hardcoded `""`. Sync
/// because the thunk is on the UI thread and so is `JavaUIActor`'s
/// executor — `assumeIsolated` is just a property read through the
/// `AndroidBinding`.
public func appcoreGetSearchQuery() -> String {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated { Bridge.getSearchQuery() }
    #else
    return ""
    #endif
}

public func appcoreDestroy() {
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.detach() }
    #endif
}
