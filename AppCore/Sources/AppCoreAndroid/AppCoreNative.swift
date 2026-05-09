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
// Command-shaped mutations are funnelled through one typed thunk per
// `AppEvent` case (`appcoreToggleRead`, `appcoreOpenStory`, `appcoreRefresh`),
// each of which builds the matching `AppEvent` value on the Swift side and
// enqueues it on the model. Per-composable reactive reads use the fused
// `appcoreObserveGet*` thunks; each atomically registers a per-property
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

/// Typed thunks per `AppEvent` case. The Swift side owns the mapping
/// from "JNI surface" to "domain event", so the wire is plain primitives
/// (`String`, no payload, etc.) and there is no JSON encoder/decoder on
/// either side of the boundary. Adding a new case to `AppEvent` means
/// adding a sibling thunk here and a `when` arm in `AppModelHolder.dispatch`.
public func appcoreToggleRead(id: String) {
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.enqueueDispatch(.toggleRead(id: id)) }
    #endif
}

public func appcoreOpenStory(id: String) {
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.enqueueDispatch(.openStory(id: id)) }
    #endif
}

public func appcoreRefresh() {
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.enqueueDispatch(.refresh) }
    #endif
}

/// Awaitable cousin of `appcoreRefresh()`. Mirrors iOS's
/// `AppEventDispatch.run(.refresh) async` — the awaitable side of the
/// sync/async dispatch duality. The Kotlin-side `awaitWithCompletion`
/// helper passes a single-shot `AndroidCompletion`; this thunk hands
/// it to `Bridge.enqueueAwaitableDispatch`, which spawns a Task that
/// awaits the model dispatch end-to-end and then fires
/// `completion.complete()`.
///
/// Pull-to-refresh in Compose is the primary consumer: the awaiting
/// coroutine keeps the indicator visible for the full fetch lifetime,
/// no race with snapshot propagation. Only `refresh` has an awaitable
/// variant today; toggle/open are fire-and-forget on both platforms,
/// so a parallel `*Await` on those cases would be unused weight.
public func appcoreRefreshAwait(completion: some AndroidCompletion) {
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.enqueueAwaitableDispatch(.refresh, completion: completion) }
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
///
/// **Why the `Task` hop in `onChange`** (not `assumeIsolated`):
/// `withObservationTracking`'s `onChange` fires synchronously *inside*
/// the property's `willSet`, before the mutation has committed. Kotlin's
/// `onChange` re-enters Swift to re-register tracking via another
/// `appcoreObserveGet*` call — and that nested read sees the pre-mutation
/// value (the getter still returns the old backing storage during willSet).
/// The result is `MutableState` written with stale values: `isLoading=true`
/// is observed as `false`, then `isLoading=false` is observed as `true` —
/// the spinner stays asserted forever and stories never paint. Hopping
/// through `Task { @JavaUIActor in … }` enqueues `callback.onChange()`
/// onto the looper after the current synchronous frame (the setter and
/// any sibling commits) unwinds, so the recursive read sees the final
/// committed state. Matches the contract documented on `ObservationCallback`.
#if canImport(Android)
@JavaUIActor
private func observeGet<T>(_ read: (AppState) -> T, callback: some ObservationCallback) -> T {
    withObservationTracking {
        read(Bridge.appModel.state)
    } onChange: { [callback] in
        Task { @JavaUIActor in callback.onChange() }
    }
}
#endif

/// Fused observe+read thunks. Each atomically registers a per-property
/// observation scope AND returns the current value via `withObservationTracking`'s
/// apply-closure return, so Kotlin can cache it in `remember(counter.intValue)` —
/// no separate trailing `read()` call. Public declarations are outside the
/// `#if canImport(Android)` guard so jextract sees them on macOS; the `#else`
/// bodies are unreachable stubs (the JNI runtime is absent on macOS).
/// Fused observe-and-snapshot for `[Story]`. Atomically registers a
/// per-property dependency on `state.stories` AND returns an `Int64`
/// peer pointer to a frozen `StoriesSnapshotPeer` capturing the current
/// value. Kotlin reads fields with `appcoreStory*(handle:, index:)` and
/// must call `appcoreStoriesRelease(handle:)` exactly once when done.
///
/// The peer is created with `Unmanaged.passRetained`, so the Swift-side
/// retain count is +1 on return. `appcoreStoriesRelease` undoes that;
/// the eager Kotlin walk wraps reads in `try { … } finally { release }`.
public func appcoreObserveGetStoriesHandle(callback: some ObservationCallback) -> Int64 {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated {
        observeGet({ state -> Int64 in
            let peer = StoriesSnapshotPeer(state.stories)
            return Int64(Int(bitPattern: Unmanaged.passRetained(peer).toOpaque()))
        }, callback: callback)
    }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreStoriesCount(handle: Int64) -> Int32 {
    #if canImport(Android)
    return Int32(storiesPeer(handle).stories.count)
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreStoryId(handle: Int64, index: Int32) -> String {
    #if canImport(Android)
    return storiesPeer(handle).stories[Int(index)].id
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreStoryTitle(handle: Int64, index: Int32) -> String {
    #if canImport(Android)
    return storiesPeer(handle).stories[Int(index)].title
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreStoryAuthor(handle: Int64, index: Int32) -> String {
    #if canImport(Android)
    return storiesPeer(handle).stories[Int(index)].author
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreStoryPoints(handle: Int64, index: Int32) -> Int32 {
    #if canImport(Android)
    return Int32(storiesPeer(handle).stories[Int(index)].points)
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreStoryCommentCount(handle: Int64, index: Int32) -> Int32 {
    #if canImport(Android)
    return Int32(storiesPeer(handle).stories[Int(index)].commentCount)
    #else
    fatalError("Android-only")
    #endif
}

/// Empty string represents `nil` (Story.url is optional). Empty URLs
/// don't occur in HN data, and a sentinel keeps the JNI surface a flat
/// `String` instead of a separate hasURL/url pair.
public func appcoreStoryURL(handle: Int64, index: Int32) -> String {
    #if canImport(Android)
    return storiesPeer(handle).stories[Int(index)].url ?? ""
    #else
    fatalError("Android-only")
    #endif
}

/// Epoch millis. HN data is second-resolution upstream, so the
/// `* 1000` truncation is exact for the values we'll see in practice.
public func appcoreStoryCreatedAtMillis(handle: Int64, index: Int32) -> Int64 {
    #if canImport(Android)
    return Int64(storiesPeer(handle).stories[Int(index)].createdAt.timeIntervalSince1970 * 1000)
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreStoryIsRead(handle: Int64, index: Int32) -> Bool {
    #if canImport(Android)
    return storiesPeer(handle).stories[Int(index)].isRead
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreStoriesRelease(handle: Int64) {
    #if canImport(Android)
    let raw = UnsafeRawPointer(bitPattern: Int(handle))!
    Unmanaged<StoriesSnapshotPeer>.fromOpaque(raw).release()
    #endif
}

#if canImport(Android)
private func storiesPeer(_ handle: Int64) -> StoriesSnapshotPeer {
    let raw = UnsafeRawPointer(bitPattern: Int(handle))!
    return Unmanaged<StoriesSnapshotPeer>.fromOpaque(raw).takeUnretainedValue()
}
#endif

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
