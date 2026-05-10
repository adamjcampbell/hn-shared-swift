package com.example.appcore

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.appcore.bridge.AppCoreAndroid
import com.example.appcore.bridge.BoolOnChange
import com.example.appcore.bridge.CommandSink
import com.example.appcore.bridge.LongOnChange
import com.example.appcore.bridge.OptionalStringOnChange
import com.example.appcore.bridge.StringOnChange
import com.example.appcore.state.component1
import com.example.appcore.state.component2
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters
import java.util.Optional
import kotlin.math.roundToLong
import kotlin.system.measureNanoTime

/**
 * Latency micro-benchmarks and regression guards for the Swift→Kotlin bridge.
 *
 * The bridge uses `appcoreObserve*` thunks: each registers a long-lived
 * Task and returns `(token, initialValue)`. The typed `*OnChange`
 * callback fires on every subsequent emission carrying the new value.
 * `appcoreDestroy` sweep-cancels any tokens still outstanding.
 *
 * **Lifecycle reset.** Instrumented tests run in the same process as the
 * app, so `AppCoreApplication.onCreate` has already called
 * `AppModelHolder.start()` (→ `appcoreCreate`) by the time JUnit starts.
 * The `@Before` below detaches before each test so each `@Test` body's
 * `appcoreCreate(...)` lands in a clean state.
 */
@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class BridgePerfTest {

    @Before
    fun resetBridge() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            AppCoreAndroid.appcoreDestroy()
        }
    }

    private class CapturingSink : CommandSink {
        override fun presentURL(value: String) {}
    }

    /**
     * Implements every `*OnChange` protocol so a single instance can be
     * registered against any property. Each variant routes a notification
     * to the same channel — tests only care that *something* fired.
     */
    private class CapturingCallback :
        BoolOnChange, StringOnChange, OptionalStringOnChange, LongOnChange {
        val changes = Channel<Unit>(Channel.UNLIMITED)
        override fun onChange(value: Boolean) { changes.trySend(Unit) }
        override fun onChange(value: String) { changes.trySend(Unit) }
        override fun onChange(value: Optional<String>) { changes.trySend(Unit) }
        override fun onChange(value: Long) { changes.trySend(Unit) }
    }

    private companion object {
        const val TOGGLE_FOO_ID = "foo"
    }

    /** Registers all five observe thunks with a shared callback — any property change fires it. */
    private fun registerObserveAll(): CapturingCallback {
        val cb = CapturingCallback()
        onMain {
            AppCoreAndroid.appcoreObserveStories(cb)
            AppCoreAndroid.appcoreObserveIsLoading(cb)
            AppCoreAndroid.appcoreObserveSearchQuery(cb)
            AppCoreAndroid.appcoreObserveLastRefreshedAt(cb)
            AppCoreAndroid.appcoreObserveLoadError(cb)
        }
        return cb
    }

    private fun registerObserveStories(): CapturingCallback {
        val cb = CapturingCallback()
        onMain { AppCoreAndroid.appcoreObserveStories(cb) }
        return cb
    }

    private fun registerObserveSearchQuery(): CapturingCallback {
        val cb = CapturingCallback()
        onMain { AppCoreAndroid.appcoreObserveSearchQuery(cb) }
        return cb
    }

    /**
     * Read-only snapshot of `state.stories`: register an observation,
     * grab the initial peer from the tuple, cancel the Task immediately
     * (we don't want the long-lived emission machinery for a one-shot
     * read), then walk and release the peer.
     */
    private fun snapshotStoriesPeer(): Long {
        val cb = CapturingCallback()
        val (token, peer) = AppCoreAndroid.appcoreObserveStories(cb)
        AppCoreAndroid.appcoreCancelObservation(token)
        return peer
    }

    /**
     * Reads the first story's id (if any), releasing the peer afterwards.
     * Used by [endToEnd_toggleRoundTrip] which needs a real id to toggle.
     */
    private fun firstStoryIdOrNull(): String? {
        val peer = snapshotStoriesPeer()
        return try {
            if (AppCoreAndroid.appcoreStoriesCount(peer) > 0)
                AppCoreAndroid.appcoreStoryId(peer, 0) else null
        } finally {
            AppCoreAndroid.appcoreStoriesRelease(peer)
        }
    }

    private fun storiesCount(): Int {
        val peer = snapshotStoriesPeer()
        return try { AppCoreAndroid.appcoreStoriesCount(peer) }
        finally { AppCoreAndroid.appcoreStoriesRelease(peer) }
    }

    // MARK: - Cold-start tests (prefixed a_ to run first)

    /**
     * Immediately after `appcoreCreate`, the initial values returned in
     * each observe tuple match the AppState defaults. We register-and-
     * cancel each observation just to read the initial value — the
     * sweep-cancel in `appcoreDestroy` would also tear them down, but
     * cancelling here means we don't accumulate Tasks across the test.
     */
    @Test
    fun a_coldStart_gettersReturnDefaults() = runBlocking {
        onMain { AppCoreAndroid.appcoreCreate(CapturingSink()) }
        try {
            assertEquals(0, onMainResult { storiesCount() })
            assertEquals(false, onMainResult {
                val cb = CapturingCallback()
                val (token, initial) = AppCoreAndroid.appcoreObserveIsLoading(cb)
                AppCoreAndroid.appcoreCancelObservation(token)
                initial
            })
            assertEquals("", onMainResult {
                val cb = CapturingCallback()
                val (token, initial) = AppCoreAndroid.appcoreObserveSearchQuery(cb)
                AppCoreAndroid.appcoreCancelObservation(token)
                initial
            })
            assertEquals(Optional.empty<String>(), onMainResult {
                val cb = CapturingCallback()
                val (token, initial) = AppCoreAndroid.appcoreObserveLastRefreshedAt(cb)
                AppCoreAndroid.appcoreCancelObservation(token)
                initial
            })
            assertEquals(Optional.empty<String>(), onMainResult {
                val cb = CapturingCallback()
                val (token, initial) = AppCoreAndroid.appcoreObserveLoadError(cb)
                AppCoreAndroid.appcoreCancelObservation(token)
                initial
            })
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    /**
     * Registers an observation scope, dispatches .refresh, and verifies
     * onChange fires (isLoading transition is the first signal). Guards
     * that per-property tracking fires correctly for real property changes.
     */
    @Test
    fun a_coldStart_observationScope_firesOnRefresh() = runBlocking {
        val nanos = measureNanoTime {
            onMain { AppCoreAndroid.appcoreCreate(CapturingSink()) }
            try {
                val cb = registerObserveAll()
                onMain { AppCoreAndroid.appcoreRefresh() }
                // 10s covers real HN API latency; typically < 100 ms for the
                // first isLoading transition alone.
                withTimeout(10_000) { cb.changes.receive() }
            } finally {
                onMain { AppCoreAndroid.appcoreDestroy() }
            }
        }
        report("cold start: create → first onChange after refresh dispatch", listOf(nanos))
    }

    // MARK: - Throughput measurements

    @Test
    fun syncJniCall_overhead() = runBlocking {
        onMain { AppCoreAndroid.appcoreCreate(CapturingSink()) }
        try {
            repeat(20) { onMain { AppCoreAndroid.appcoreToggleRead(TOGGLE_FOO_ID) } }
            val samples = mutableListOf<Long>()
            repeat(200) {
                samples += measureNanoTime {
                    onMain { AppCoreAndroid.appcoreToggleRead(TOGGLE_FOO_ID) }
                }
            }
            report("sync JNI call (typed appcoreToggleRead)", samples)
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    @Test
    fun endToEnd_toggleRoundTrip() = runBlocking {
        onMain { AppCoreAndroid.appcoreCreate(CapturingSink()) }
        try {
            // Dispatch refresh once, then re-register scope on each onChange
            // until stories are populated.
            onMain { AppCoreAndroid.appcoreRefresh() }
            val storyId = withTimeout(15_000) {
                var id: String? = null
                while (id == null) {
                    val cb = registerObserveAll()
                    cb.changes.receive()
                    id = onMainResult { firstStoryIdOrNull() ?: "" }.ifEmpty { null }
                }
                id
            }

            // Warm-up: each toggle flips Story.isRead in the computed
            // `stories` property, firing onChange on the stories observer.
            repeat(20) {
                val cb = registerObserveStories()
                onMain { AppCoreAndroid.appcoreToggleRead(storyId) }
                withTimeout(1_000) { cb.changes.receive() }
            }

            val samples = mutableListOf<Long>()
            repeat(100) {
                val cb = registerObserveStories()
                val t0 = System.nanoTime()
                onMain { AppCoreAndroid.appcoreToggleRead(storyId) }
                withTimeout(1_000) { cb.changes.receive() }
                samples += System.nanoTime() - t0
            }
            report("end-to-end round-trip (toggle → onChange)", samples)
            assertTrue("samples produced", samples.size == 100)
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    @Test
    fun storiesPayload_shape() = runBlocking {
        onMain { AppCoreAndroid.appcoreCreate(CapturingSink()) }
        try {
            // Load until stories are non-empty.
            onMain { AppCoreAndroid.appcoreRefresh() }
            val rowCount = withTimeout(15_000) {
                var n = 0
                while (n == 0) {
                    val cb = registerObserveStories()
                    cb.changes.receive()
                    n = onMainResult { storiesCount() }
                }
                n
            }
            println("[BridgePerf] stories rows (loaded): $rowCount")
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    // MARK: - Thread contract

    /**
     * Canary for the `LooperExecutor` contract: `*OnChange.onChange` must
     * always arrive on Android's main Looper. Swift delivers it via a
     * `@JavaUIActor`-isolated Task whose executor is `LooperExecutor`.
     * If a future refactor drops this, Compose MutableState writes from
     * the handler would crash with a thread-confinement violation.
     */
    @Test
    fun bridgeWorkRunsOnUIThread() = runBlocking {
        val mainLooper = android.os.Looper.getMainLooper()
        val capturedLooper = Channel<android.os.Looper?>(capacity = 1)

        onMain { AppCoreAndroid.appcoreCreate(CapturingSink()) }
        try {
            val cb = object : BoolOnChange, StringOnChange, OptionalStringOnChange, LongOnChange {
                private fun capture() { capturedLooper.trySend(android.os.Looper.myLooper()) }
                override fun onChange(value: Boolean) = capture()
                override fun onChange(value: String) = capture()
                override fun onChange(value: Optional<String>) = capture()
                override fun onChange(value: Long) = capture()
            }
            onMain {
                AppCoreAndroid.appcoreObserveStories(cb)
                AppCoreAndroid.appcoreObserveIsLoading(cb)
                AppCoreAndroid.appcoreObserveSearchQuery(cb)
                AppCoreAndroid.appcoreObserveLastRefreshedAt(cb)
                AppCoreAndroid.appcoreObserveLoadError(cb)
            }
            onMain { AppCoreAndroid.appcoreRefresh() }
            val looper = withTimeout(5_000) { capturedLooper.receive() }
            assertEquals(
                "*OnChange.onChange must run on Android's main Looper",
                mainLooper,
                looper,
            )
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    // MARK: - Per-property getter and setter contracts

    @Test
    fun getSearchQuery_returnsCurrentSwiftValue() = runBlocking {
        onMain { AppCoreAndroid.appcoreCreate(CapturingSink()) }
        try {
            // Initial value via observe's tuple, then cancel.
            assertEquals("cold-start initial value is empty", "",
                onMainResult {
                    val cb = CapturingCallback()
                    val (token, initial) = AppCoreAndroid.appcoreObserveSearchQuery(cb)
                    AppCoreAndroid.appcoreCancelObservation(token)
                    initial
                })
            onMain { AppCoreAndroid.appcoreSetSearchQuery("hello") }
            assertEquals("observe's initial slot reflects the value just set", "hello",
                onMainResult {
                    val cb = CapturingCallback()
                    val (token, initial) = AppCoreAndroid.appcoreObserveSearchQuery(cb)
                    AppCoreAndroid.appcoreCancelObservation(token)
                    initial
                })
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    /**
     * Writing to searchQuery via the JNI setter fires onChange on any open
     * scope that read searchQuery. Verifies the per-property observation
     * tracking works for setter-driven writes (not only dispatch-driven ones).
     */
    @Test
    fun searchQuery_observationScope_firesOnSet() = runBlocking {
        onMain { AppCoreAndroid.appcoreCreate(CapturingSink()) }
        try {
            val cb = registerObserveSearchQuery()
            onMain { AppCoreAndroid.appcoreSetSearchQuery("rust") }
            withTimeout(1_000) { cb.changes.receive() }
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    // MARK: - Helpers

    private fun onMain(block: () -> Unit) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync(block)
    }

    private fun <T : Any> onMainResult(block: () -> T): T {
        lateinit var result: T
        InstrumentationRegistry.getInstrumentation().runOnMainSync { result = block() }
        return result
    }

    private fun report(label: String, samplesNs: List<Long>) {
        if (samplesNs.isEmpty()) {
            println("[BridgePerf] $label: no samples")
            return
        }
        val sorted = samplesNs.sorted()
        val n = sorted.size
        val median = sorted[n / 2]
        val p99 = sorted[((n - 1) * 0.99).roundToLong().toInt()]
        val mean = sorted.sum() / n
        println(
            "[BridgePerf] $label  n=$n  median=${fmt(median)}  mean=${fmt(mean)}  p99=${fmt(p99)}"
        )
    }

    private fun fmt(ns: Long): String = when {
        ns < 10_000       -> "${ns}ns"
        ns < 10_000_000   -> "${ns / 1_000}µs"
        else              -> "${ns / 1_000_000}ms"
    }
}
