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

// MARK: - Observation registration / cancellation
//
// `appcoreObserve*` is the fused registration thunk: spawns a Task that
// iterates `Observations { … }.dropFirst()` for the property and
// returns a `(token, initialValue)` tuple. The `OnChange` callback
// fires on every subsequent emission until cancelled.
//
// `appcoreRead*` reads the current value without registering — Kotlin's
// `OnChange` handler calls it once per emission to refresh
// `MutableState.value`.
//
// `appcoreCancelObservation(token)` cancels the Task immediately — the
// for-await loop exits, the OnChange capture is released, the JNI
// global ref drops, and GC reclaims the chain. `Bridge.detach`
// sweep-cancels any tokens still outstanding.
//
// **Why `Observations` (not `withObservationTracking`).** `Observations`
// (SE-0475) emits at transaction end (after didSet), not inside willSet —
// so synchronous re-reads from the OnChange handler see post-mutation
// state. Both the writer and the awaiting Task share `LooperExecutor`,
// so the AsyncSequence's continuation resumes on the main thread on the
// next runloop iteration after the writer's setter unwinds.
//
// **Why a tuple return.** jextract bridges Swift tuples to
// `org.swift.swiftkit.core.tuple.Tuple2` via a single thunk that uses
// per-element out-param arrays internally and constructs the wrapper
// on return. Returning `(token, value)` from one thunk fuses what
// would otherwise need two round-trips (register → token, then read →
// initial value). See `docs/observation-bridge-tuple-return.md` for
// the rationale.

#if canImport(Android)
@JavaUIActor
private func observe<T: Sendable>(
    _ read: @escaping @Sendable (AppState) -> T,
    callback: some OnChange,
) -> (Int64, T) {
    let task = Task {
        for await _ in Observations({ read(Bridge.appModel.state) }).dropFirst() {
            callback.onChange()
        }
    }
    let token = Bridge.registerObservation(task)
    return (token, read(Bridge.appModel.state))
}
#endif

/// Cancels the observation Task identified by [token]. Safe to call from
/// any thread that holds the `JavaUIActor` contract (Compose's main
/// thread). Calling twice with the same token is a no-op (the token has
/// already been removed from the registry).
public func appcoreCancelObservation(token: Int64) {
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.cancelObservation(token) }
    #endif
}

// MARK: - Per-property observe + read thunks
//
// Public declarations are outside the `#if canImport(Android)` guard so
// jextract sees them on macOS; the `#else` bodies are unreachable stubs
// (the JNI runtime is absent on macOS).

/// Registers a long-lived observation on `state.stories` and returns
/// `(token, peerHandle)` — the cancellation token plus an `Int64` peer
/// pointer to a `StoriesSnapshotPeer` capturing the current snapshot.
/// Kotlin reads fields with `appcoreStory*(handle:, index:)` and must
/// call `appcoreStoriesRelease(handle:)` exactly once when done.
///
/// The peer is created with `Unmanaged.passRetained`, so the Swift-side
/// retain count is +1 on return. `appcoreStoriesRelease` undoes that;
/// the eager Kotlin walk wraps reads in `try { … } finally { release }`.
public func appcoreObserveStories(callback: some OnChange) -> (Int64, Int64) {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated {
        observe({ state -> Int64 in
            let peer = StoriesSnapshotPeer(state.stories)
            return Int64(Int(bitPattern: Unmanaged.passRetained(peer).toOpaque()))
        }, callback: callback)
    }
    #else
    fatalError("Android-only")
    #endif
}

/// Reads the current `state.stories` without registering an observation.
/// Kotlin calls this from the OnChange handler to refresh the snapshot
/// after a mutation. Returns a freshly-retained `StoriesSnapshotPeer`
/// peer pointer; release with `appcoreStoriesRelease`.
public func appcoreReadStoriesHandle() -> Int64 {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated {
        let peer = StoriesSnapshotPeer(Bridge.appModel.state.stories)
        return Int64(Int(bitPattern: Unmanaged.passRetained(peer).toOpaque()))
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

public func appcoreStoryURL(handle: Int64, index: Int32) -> String? {
    #if canImport(Android)
    return storiesPeer(handle).stories[Int(index)].url
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

public func appcoreObserveIsLoading(callback: some OnChange) -> (Int64, Bool) {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated { observe(\.isLoading, callback: callback) }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreReadIsLoading() -> Bool {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated { Bridge.appModel.state.isLoading }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreObserveSearchQuery(callback: some OnChange) -> (Int64, String) {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated { observe(\.searchQuery, callback: callback) }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreReadSearchQuery() -> String {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated { Bridge.appModel.state.searchQuery }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreObserveLastRefreshedAt(callback: some OnChange) -> (Int64, String?) {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated {
        observe({ $0.lastRefreshedAt.map { ISO8601DateFormatter().string(from: $0) } }, callback: callback)
    }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreReadLastRefreshedAt() -> String? {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated {
        Bridge.appModel.state.lastRefreshedAt.map { ISO8601DateFormatter().string(from: $0) }
    }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreObserveLoadError(callback: some OnChange) -> (Int64, String?) {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated { observe(\.loadError, callback: callback) }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreReadLoadError() -> String? {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated { Bridge.appModel.state.loadError }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreDestroy() {
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.detach() }
    #endif
}
