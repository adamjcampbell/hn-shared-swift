import Foundation
import AppCore
import Observation

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
// that decodes a Codable `AppEvent`. Per-composable reactive reads use the
// fused `appcoreObserveGet*` thunks; each atomically registers a per-property
// dependency and returns the current value in one JNI hop.
//
// **Sync entry via `JavaUIActor.assumeIsolated`.** `JavaUIActor` is a
// global actor pinned to Android's main `Looper` via `LooperExecutor`.
// Compose always calls these thunks from the UI thread, which *is* the
// global actor's executor, so `JavaUIActor.assumeIsolated` lets the
// thunks enter the actor's isolation domain synchronously without
// `Task { await … }` allocation.
//
// **Contract.** Calling these thunks off the UI thread on Android, or
// at all on the macOS host, will trap inside `assumeIsolated`. Compose
// only ever calls them from the UI thread; the macOS host build never
// invokes them (the JNI runtime isn't present). On macOS the bodies
// are `#if canImport(Android)`-gated to no-ops so jextract still sees
// the public-API signatures. See AGENT.md.

public func appcoreCreate(commandSink: some CommandSink) {
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.attach(commandSink: commandSink) }
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
/// every keystroke via the JNI thunk.
public func appcoreSetSearchQuery(value: String) {
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.handleSetSearchQuery(value) }
    #endif
}

/// Private helper, Android-only. `@JavaUIActor`-isolated so `read` and
/// `Bridge.appModel.state` are accessed in the same domain — no actor
/// boundary to cross, no Sendable requirement on `read`.
#if canImport(Android)
@JavaUIActor
private func observeGet<T>(_ read: (AppState) -> T, callback: some ObservationCallback) -> T {
    withObservationTracking {
        read(Bridge.appModel.state)
    } onChange: {
        JavaUIActor.assumeIsolated { callback.onChange() }
    }
}
#endif

/// Fused observe+read thunks. Each atomically registers a per-property
/// observation scope AND returns the current value via `withObservationTracking`'s
/// apply-closure return, so Kotlin can cache it in `remember(counter.intValue)` —
/// no separate trailing `read()` call. Public declarations are outside the
/// `#if canImport(Android)` guard so jextract sees them on macOS; the `#else`
/// bodies are unreachable stubs (the JNI runtime is absent on macOS).
public func appcoreObserveGetStoriesJSON(callback: some ObservationCallback) -> String {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated { observeGet({ JNICoder.encode($0.stories) }, callback: callback) }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreObserveGetIsLoading(callback: some ObservationCallback) -> Bool {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated { observeGet(\.isLoading, callback: callback) }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreObserveGetSearchQuery(callback: some ObservationCallback) -> String {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated { observeGet(\.searchQuery, callback: callback) }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreObserveGetLastRefreshedAt(callback: some ObservationCallback) -> String {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated { observeGet({ $0.lastRefreshedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "" }, callback: callback) }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreObserveGetLoadError(callback: some ObservationCallback) -> String {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated { observeGet({ $0.loadError ?? "" }, callback: callback) }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreDestroy() {
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.detach() }
    #endif
}
