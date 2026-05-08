package com.example.appcore.bridge

import android.os.Handler
import android.os.Looper

/**
 * Java side of `LooperExecutor`'s post-to-main mechanism.
 *
 * `JavaUIActor` (Swift global actor) pins its custom `SerialExecutor`
 * (`LooperExecutor`) to Android's main `Looper`. When Swift's runtime
 * calls `LooperExecutor.enqueue(_:)` from a non-UI thread (e.g. an
 * `Observations` task waking up off-actor), the executor packs the job
 * pointer into a `Long` and calls `postToMain` here. We then
 * `Handler.post { … }` the work onto the main `Looper`, where Android
 * dispatches the lambda back into Swift via the [runSwiftJob]
 * `external` JNI binding.
 *
 * **Object, not class.** A static method is the simplest possible
 * Swift→Kotlin call shape — no instance to construct, no global ref to
 * cache on the Swift side. We do cache the `jclass` and
 * `jmethodID` for `postToMain` once on the Swift side (see
 * `LooperExecutor.lookupCached`); from then on each post is two JNI
 * calls (`CallStaticVoidMethod` here + `RegisterNatives`-resolved
 * upcall on `runSwiftJob`).
 *
 * **Bootstrap.** `Handler(Looper.getMainLooper())` is constructed in the
 * Kotlin `object`'s static initializer the first time `postToMain` is
 * called. Android's `Looper.getMainLooper()` is process-stable, so the
 * `Handler` is safe to keep for the lifetime of the process. No
 * explicit Swift-side bootstrap step is needed: the first
 * `LooperExecutor.enqueue` call lazily initializes everything via the
 * normal class-init path.
 *
 * **`.so` loading.** `runSwiftJob` is implemented as a Swift `@_cdecl`
 * (`Java_com_example_appcore_bridge_LooperPoster_runSwiftJob` in
 * `AppCore/Sources/AppCoreAndroid/LooperExecutor.swift`). It lives in
 * `libAppCoreAndroid.so`, which is loaded automatically the first
 * time any other `com.example.appcore.bridge.*` class (notably
 * `AppCoreAndroid` itself) triggers its static initializer. By the
 * time any actor work is enqueued, `AppCoreApplication.onCreate` has
 * already called `AppModelHolder.start()` — which references
 * `AppCoreAndroid.appcoreCreate` — so the `.so` is loaded.
 */
internal object LooperPoster {
    private val handler = Handler(Looper.getMainLooper())

    @JvmStatic
    fun postToMain(jobPointer: Long) {
        handler.post { runSwiftJob(jobPointer) }
    }

    /**
     * Called from `LooperExecutor.checkIsolated()` (Swift) to answer
     * "is the current thread the executor's expected thread?" — i.e.
     * Android's main `Looper`. Swift's runtime invokes `checkIsolated`
     * whenever it needs to verify actor isolation (e.g. inside
     * `JavaUIActor.assumeIsolated`); without this hook the default impl
     * always traps because Swift can't otherwise tell that Android's
     * main thread *is* the global actor's executor.
     */
    @JvmStatic
    fun isOnMainLooper(): Boolean =
        Looper.myLooper() == Looper.getMainLooper()

    @JvmStatic
    private external fun runSwiftJob(jobPointer: Long)
}
