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
/// sync/async dispatch duality.
///
/// Returns a cancellation token (registered in `Bridge.tasks`) so the
/// Kotlin-side coroutine can cooperatively cancel an in-flight refresh
/// via `appcoreCancelTask(token)` if it's torn down before the dispatch
/// completes. `Bridge.detach` (called by `appcoreDestroy`) also sweeps
/// any tokens still outstanding.
///
/// Pull-to-refresh in Compose is the primary consumer: the awaiting
/// coroutine keeps the indicator visible for the full fetch lifetime,
/// no race with snapshot propagation. Only `refresh` has an awaitable
/// variant today; toggle/open are fire-and-forget on both platforms,
/// so a parallel `*Await` on those cases would be unused weight.
public func appcoreRefreshAwait(completion: some AndroidCompletion) -> Int64 {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated {
        Bridge.enqueueAwaitableDispatch(.refresh, completion: completion)
    }
    #else
    completion.complete()
    return 0
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
// returns a `(token, initialValue)` tuple. The typed `*OnChange`
// callback fires on every subsequent emission carrying the new value;
// Kotlin's handler writes it directly to `MutableState.value` without
// a separate read round-trip.
//
// `appcoreCancelObservation(token)` cancels the Task immediately — the
// for-await loop exits, the OnChange capture is released, the JNI
// global ref drops, and GC reclaims the chain. `Bridge.detach`
// sweep-cancels any tokens still outstanding.
//
// **Why `Observations` (not `withObservationTracking`).** `Observations`
// (SE-0475) emits at transaction end (after didSet), not inside willSet —
// so the value the producer yields is the post-mutation value, ready to
// ship to Kotlin without a re-read. Both the writer and the awaiting
// Task share `LooperExecutor`, so the AsyncSequence's continuation
// resumes on the main thread on the next runloop iteration after the
// writer's setter unwinds.
//
// **Why a tuple return.** jextract bridges Swift tuples to
// `org.swift.swiftkit.core.tuple.Tuple2` via a single thunk that uses
// per-element out-param arrays internally and constructs the wrapper
// on return. Returning `(token, initial)` from one thunk fuses what
// would otherwise need two round-trips. See
// `docs/observation-bridge-tuple-return.md` for the rationale.
//
// **Why typed `*OnChange` protocols.** jextract doesn't bridge generic
// protocols, so each observed value type needs its own SAM-friendly
// Java interface. Value-carrying callbacks halve the per-emission JNI
// cost: one S→K thunk that delivers the value, instead of one S→K
// notification followed by a K→S read. See `OnChange.swift` for the
// per-type protocols and `docs/observation-bridge-value-carrying.md`
// for the cost analysis.

#if canImport(Android)
/// Generic helper: spawn an observation Task that delivers each
/// post-mutation value to `onChange`, then return `(token, initial)`.
/// Per-property thunks specialize this by adapting from a typed
/// `*OnChange` protocol callback to a Swift closure.
@JavaUIActor
private func observe<T: Sendable>(
    _ read: @escaping @Sendable (AppState) -> T,
    onChange: @escaping @Sendable (T) -> Void,
) -> (Int64, T) {
    let initial = read(Bridge.appModel.state)
    let task = Task {
        for await value in Observations({ read(Bridge.appModel.state) }).dropFirst() {
            onChange(value)
        }
    }
    let token = Bridge.registerTask(task)
    return (token, initial)
}
#endif

/// Cancels the Task identified by [token]. Used to:
/// - Tear down an observation (token from `appcoreObserve*`) when the
///   Compose binding disposes.
/// - Cooperatively cancel an awaitable dispatch (token from
///   `appcoreRefreshAwait`) when the awaiting Kotlin coroutine is
///   cancelled.
///
/// Safe to call from any thread that holds the `JavaUIActor` contract
/// (Compose's main thread). Calling twice with the same token is a
/// no-op — the registry entry has already been removed.
public func appcoreCancelTask(token: Int64) {
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.cancelTask(token) }
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
/// On every subsequent emission the callback fires with a fresh peer
/// pointer for the new snapshot; Kotlin walks fields with
/// `appcoreStory*(handle:, index:)` and must call
/// `appcoreStoriesRelease(handle:)` exactly once per peer.
///
/// Each peer is created with `Unmanaged.passRetained`, so the Swift-side
/// retain count is +1 on return / per emission. `appcoreStoriesRelease`
/// undoes that; the eager Kotlin walk wraps reads in `try { … } finally
/// { release }`.
///
/// **Inline (not `observe<T>`)** because the generic helper would
/// allocate a wasted peer on Observations' dropped initial emission.
/// Here we keep tracking-only inside the producer (`_ = state.stories`)
/// and allocate peers only at points we'll actually deliver: the eager
/// `initial` and each post-`dropFirst()` emission.
public func appcoreObserveStories(callback: some LongOnChange) -> (Int64, Int64) {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated {
        let initial = makeStoriesPeer()
        let task = Task {
            for await _ in Observations({ _ = Bridge.appModel.state.stories }).dropFirst() {
                callback.onChange(value: makeStoriesPeer())
            }
        }
        let token = Bridge.registerTask(task)
        return (token, initial)
    }
    #else
    fatalError("Android-only")
    #endif
}

#if canImport(Android)
@JavaUIActor
private func makeStoriesPeer() -> Int64 {
    let peer = StoriesSnapshotPeer(Bridge.appModel.state.stories)
    return Int64(Int(bitPattern: Unmanaged.passRetained(peer).toOpaque()))
}
#endif

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

public func appcoreObserveIsLoading(callback: some BoolOnChange) -> (Int64, Bool) {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated {
        observe(\.isLoading) { value in callback.onChange(value: value) }
    }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreObserveSearchQuery(callback: some StringOnChange) -> (Int64, String) {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated {
        observe(\.searchQuery) { value in callback.onChange(value: value) }
    }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreObserveLastRefreshedAt(callback: some OptionalStringOnChange) -> (Int64, String?) {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated {
        observe({ $0.lastRefreshedAt.map { ISO8601DateFormatter().string(from: $0) } }) { value in
            callback.onChange(value: value)
        }
    }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreObserveLoadError(callback: some OptionalStringOnChange) -> (Int64, String?) {
    #if canImport(Android)
    return JavaUIActor.assumeIsolated {
        observe(\.loadError) { value in callback.onChange(value: value) }
    }
    #else
    fatalError("Android-only")
    #endif
}

public func appcoreDestroy() {
    #if canImport(Android)
    JavaUIActor.assumeIsolated { Bridge.detach() }
    #endif
}
