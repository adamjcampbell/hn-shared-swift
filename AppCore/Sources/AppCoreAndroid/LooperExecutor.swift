#if canImport(Android)
import Foundation
import Synchronization
import SwiftJavaJNICore

/// Custom `SerialExecutor` that posts jobs onto Android's main `Looper`.
///
/// Adopted by `JavaUIActor` (via its `nonisolated var unownedExecutor`)
/// so all `@JavaUIActor`-isolated work runs on the Android UI thread —
/// `state.searchQuery` writes from `appcoreSetSearchQuery`, sink
/// callbacks via `SnapshotSink` / `CommandSink` / `SearchQuerySink`,
/// and the search-query watcher's debounced fetch trigger all land on
/// the UI thread directly. Avoids an extra cross-thread post inside
/// Compose's recomposition path; keeps `AttachCurrentThread` on the
/// fast path because the executing thread is always JNI-attached.
///
/// **Android-only.** This file compiles to nothing on macOS (the whole
/// body is `#if canImport(Android)`-gated). On the macOS host build
/// `JavaUIActor` itself is also `#if canImport(Android)`-gated, so we
/// don't need a fake macOS executor. `swift test` doesn't pull the
/// Android-only bridge bodies; only jextract's macOS-side scan of the
/// public-API signatures.
///
/// **Bootstrap**: Kotlin's `LooperPoster` static object captures
/// `Handler(Looper.getMainLooper())` in its static initializer, so the
/// first `enqueue` call lazily initializes everything on the JVM side.
/// No explicit Swift bootstrap is needed.
final class LooperExecutor: SerialExecutor {
    static let shared = LooperExecutor()

    private let cache = Mutex<_PosterCache>(.empty)

    private init() {}

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        // `UnownedJob` is a stdlib struct with no public `bitPattern:`
        // API; bit-cast through `Int64` is the canonical pattern for
        // crossing it through a Java `long`. The reverse lives in the
        // `runSwiftJob` `@_cdecl` below.
        let jobPointer = unsafeBitCast(unownedJob, to: Int64.self)
        // The JVM is always up by the time anything in this module
        // executes — the `.so` is loaded by `AppCoreAndroid`'s static
        // initializer on Kotlin first reference. `try!` traps loudly
        // if that invariant ever breaks, which is the right failure
        // mode for an executor (silently dropping jobs would be worse).
        let env = try! JavaVirtualMachine.shared().environment()
        let handles = lookupCached(env: env)
        var args = jvalue(j: jobPointer)
        withUnsafePointer(to: &args) { argsPtr in
            env.pointee!.pointee.CallStaticVoidMethodA(
                env, handles.cls, handles.postToMain, argsPtr
            )
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Override of `SerialExecutor.checkIsolated()` (Swift 6+). Swift's
    /// runtime calls this from `Actor.assumeIsolated` (and similar
    /// isolation checks) to verify the calling thread is the executor's
    /// expected thread. Without this override the default impl always
    /// traps with "Unexpected isolation context, expected to be
    /// executing on LooperExecutor", because Swift has no way to know
    /// that Android's main `Looper` thread *is* this executor's domain.
    /// We answer the question by calling `LooperPoster.isOnMainLooper()`
    /// via JNI.
    func checkIsolated() {
        let env = try! JavaVirtualMachine.shared().environment()
        let handles = lookupCached(env: env)
        let result = env.pointee!.pointee.CallStaticBooleanMethodA(
            env, handles.cls, handles.isOnMainLooper, nil
        )
        precondition(
            result != 0,
            "LooperExecutor.checkIsolated: not on Android's main Looper. " +
            "JNI thunks may only be called from the UI thread."
        )
    }

    private struct CachedHandles {
        let cls: jclass
        let postToMain: jmethodID
        let isOnMainLooper: jmethodID
    }

    /// Resolve and cache JNI handles for `LooperPoster`'s class and
    /// the static methods we call on it. Caches under the executor's
    /// lock so subsequent calls skip the `FindClass` +
    /// `GetStaticMethodID` lookups.
    ///
    /// Returns raw bit patterns from the lock closure — `jclass` and
    /// `jmethodID` are non-`Sendable` raw pointers, and returning
    /// them from `withLock` would be flagged as a task-isolated
    /// `sending` violation. The `UInt` round-trip is pointer-equivalent
    /// (`UInt(bitPattern:)` and `jclass(bitPattern:)` are inverses for
    /// `_Pointer`) and crosses the Sendable boundary cleanly; we
    /// reconstruct via `bitPattern:` initialisers at the call site.
    private func lookupCached(env: JNIEnvironment) -> CachedHandles {
        let (clsBits, postBits, checkBits) = cache.withLock { cache -> (UInt, UInt, UInt) in
            if case .ready(let c, let p, let i) = cache {
                return (c, p, i)
            }
            // First call: resolve and cache.
            let localCls: jclass = "com/example/appcore/bridge/LooperPoster".withCString { name in
                env.pointee!.pointee.FindClass(env, name)!
            }
            // Promote to global ref so the cached jclass survives across
            // local frames.
            let globalCls: jclass = env.pointee!.pointee.NewGlobalRef(env, localCls)!
            let postMid: jmethodID = "postToMain".withCString { name in
                "(J)V".withCString { sig in
                    env.pointee!.pointee.GetStaticMethodID(env, globalCls, name, sig)!
                }
            }
            let checkMid: jmethodID = "isOnMainLooper".withCString { name in
                "()Z".withCString { sig in
                    env.pointee!.pointee.GetStaticMethodID(env, globalCls, name, sig)!
                }
            }
            let cBits = UInt(bitPattern: globalCls)
            let pBits = UInt(bitPattern: postMid)
            let iBits = UInt(bitPattern: checkMid)
            cache = .ready(cls: cBits, postToMain: pBits, isOnMainLooper: iBits)
            return (cBits, pBits, iBits)
        }
        return CachedHandles(
            cls: jclass(bitPattern: clsBits)!,
            postToMain: jmethodID(bitPattern: postBits)!,
            isOnMainLooper: jmethodID(bitPattern: checkBits)!
        )
    }
}

/// Cache state for `LooperPoster`'s JNI handles. `jclass` and
/// `jmethodID` are opaque pointers into the JVM; once promoted to a
/// global ref they're safe to share across threads. Stored as raw
/// `UInt` bit patterns so the enum is unconditionally `Sendable` —
/// `UnsafeMutableRawPointer` isn't `Sendable` under Swift 6, but the
/// integer bit pattern is, and `bitPattern:` initializers round-trip
/// the value unchanged at the use site.
private enum _PosterCache: Sendable {
    case empty
    case ready(cls: UInt, postToMain: UInt, isOnMainLooper: UInt)
}

/// JNI binding for `LooperPoster.runSwiftJob(jobPointer:)`. Called
/// from a `Handler.post { … }` lambda on Android's main `Looper`,
/// so the executing thread is the UI thread — exactly the executor
/// `LooperExecutor` claims to run jobs on. Reconstructs the
/// `UnownedJob` from its bit-pattern and runs it synchronously on
/// `LooperExecutor.shared`.
///
/// Kotlin side: `external @JvmStatic fun runSwiftJob(jobPointer: Long)`
/// in `object LooperPoster` (package `com.example.appcore.bridge`).
/// JNI's static-method calling convention takes `(JNIEnv*, jclass, args…)`.
/// The cdecl name follows JNI's `Java_<package>_<class>_<method>`
/// mangling (with `/` → `_`).
@_cdecl("Java_com_example_appcore_bridge_LooperPoster_runSwiftJob")
public func Java_com_example_appcore_bridge_LooperPoster_runSwiftJob(
    env: JNIEnvironment,
    cls: jclass,
    jobPointer: Int64
) {
    let unownedJob = unsafeBitCast(jobPointer, to: UnownedJob.self)
    unownedJob.runSynchronously(on: LooperExecutor.shared.asUnownedSerialExecutor())
}
#endif
