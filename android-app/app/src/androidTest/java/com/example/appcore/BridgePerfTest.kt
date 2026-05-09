package com.example.appcore

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.appcore.bridge.AppCoreAndroid
import com.example.appcore.bridge.CommandSink
import com.example.appcore.bridge.ObservationCallback
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
import kotlin.math.roundToLong
import kotlin.system.measureNanoTime

/**
 * Latency micro-benchmarks and regression guards for the Swift→Kotlin bridge.
 *
 * The bridge uses fused `appcoreObserveGet*` thunks: each atomically registers
 * a per-property dependency AND returns the current value in one JNI hop.
 * Re-registration is the composable's responsibility — these tests mirror that
 * cycle explicitly via [registerObserveAll], [registerObserveStories], and
 * [registerObserveSearchQuery].
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
        override fun deliverCommand(commandJSON: String) {}
    }

    private class CapturingCallback : ObservationCallback {
        val changes = Channel<Unit>(Channel.UNLIMITED)
        override fun onChange() { changes.trySend(Unit) }
    }

    private val noOp = object : ObservationCallback { override fun onChange() {} }

    private companion object {
        const val TOGGLE_FOO_JSON = """{"type":"toggleRead","id":"foo"}"""
        const val REFRESH_JSON    = """{"type":"refresh"}"""
        val FIRST_ID_REGEX = Regex("\"id\":\"([^\"]+)\"")
    }

    /** Registers all five fused thunks with a shared callback — any property change fires it. */
    private fun registerObserveAll(): CapturingCallback {
        val cb = CapturingCallback()
        onMain {
            AppCoreAndroid.appcoreObserveGetStoriesJSON(cb)
            AppCoreAndroid.appcoreObserveGetIsLoading(cb)
            AppCoreAndroid.appcoreObserveGetSearchQuery(cb)
            AppCoreAndroid.appcoreObserveGetLastRefreshedAt(cb)
            AppCoreAndroid.appcoreObserveGetLoadError(cb)
        }
        return cb
    }

    private fun registerObserveStories(): CapturingCallback {
        val cb = CapturingCallback()
        onMain { AppCoreAndroid.appcoreObserveGetStoriesJSON(cb) }
        return cb
    }

    private fun registerObserveSearchQuery(): CapturingCallback {
        val cb = CapturingCallback()
        onMain { AppCoreAndroid.appcoreObserveGetSearchQuery(cb) }
        return cb
    }

    // MARK: - Cold-start tests (prefixed a_ to run first)

    /**
     * Immediately after `appcoreCreate`, all property getters return their
     * zero-values. There's no Observations initial-emission race to guard
     * against — the composable reads current values directly.
     */
    @Test
    fun a_coldStart_gettersReturnDefaults() = runBlocking {
        onMain { AppCoreAndroid.appcoreCreate(CapturingSink()) }
        try {
            assertEquals("[]", onMainResult { AppCoreAndroid.appcoreObserveGetStoriesJSON(noOp) })
            assertEquals(false, onMainResult { AppCoreAndroid.appcoreObserveGetIsLoading(noOp) })
            assertEquals("", onMainResult { AppCoreAndroid.appcoreObserveGetSearchQuery(noOp) })
            assertEquals("", onMainResult { AppCoreAndroid.appcoreObserveGetLastRefreshedAt(noOp) })
            assertEquals("", onMainResult { AppCoreAndroid.appcoreObserveGetLoadError(noOp) })
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
                onMain { AppCoreAndroid.appcoreDispatch(REFRESH_JSON) }
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
            repeat(20) { onMain { AppCoreAndroid.appcoreDispatch(TOGGLE_FOO_JSON) } }
            val samples = mutableListOf<Long>()
            repeat(200) {
                samples += measureNanoTime {
                    onMain { AppCoreAndroid.appcoreDispatch(TOGGLE_FOO_JSON) }
                }
            }
            report("sync JNI call (dispatch — incl. JSON decode)", samples)
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
            onMain { AppCoreAndroid.appcoreDispatch(REFRESH_JSON) }
            val storyId = withTimeout(15_000) {
                var id: String? = null
                while (id == null) {
                    val cb = registerObserveAll()
                    cb.changes.receive()
                    val json = onMainResult { AppCoreAndroid.appcoreObserveGetStoriesJSON(noOp) }
                    id = FIRST_ID_REGEX.find(json)?.groupValues?.get(1)
                }
                id
            }
            val toggleStory = """{"type":"toggleRead","id":"$storyId"}"""

            // Warm-up: each toggle flips Story.isRead in the computed
            // `stories` property, firing onChange on the stories observer.
            repeat(20) {
                val cb = registerObserveStories()
                onMain { AppCoreAndroid.appcoreDispatch(toggleStory) }
                withTimeout(1_000) { cb.changes.receive() }
            }

            val samples = mutableListOf<Long>()
            repeat(100) {
                val cb = registerObserveStories()
                val t0 = System.nanoTime()
                onMain { AppCoreAndroid.appcoreDispatch(toggleStory) }
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
    fun storiesPayload_size() = runBlocking {
        onMain { AppCoreAndroid.appcoreCreate(CapturingSink()) }
        try {
            // Load until stories are non-empty.
            onMain { AppCoreAndroid.appcoreDispatch(REFRESH_JSON) }
            val loaded = withTimeout(15_000) {
                var json = "[]"
                while (!json.contains("{")) {
                    val cb = registerObserveStories()
                    cb.changes.receive()
                    json = onMainResult { AppCoreAndroid.appcoreObserveGetStoriesJSON(noOp) }
                }
                json
            }
            println("[BridgePerf] stories JSON bytes (loaded, no reads): ${loaded.toByteArray().size}")
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    // MARK: - Thread contract

    /**
     * Canary for the `LooperExecutor` contract: `ObservationCallback.onChange`
     * must always arrive on Android's main Looper. Swift delivers it via
     * `Task { @JavaUIActor in callback.onChange() }`, which pins to the main
     * Looper through `LooperExecutor`. If a future refactor drops this,
     * Compose MutableState writes from `onChange` would crash with a
     * thread-confinement violation.
     */
    @Test
    fun bridgeWorkRunsOnUIThread() = runBlocking {
        val mainLooper = android.os.Looper.getMainLooper()
        val capturedLooper = Channel<android.os.Looper?>(capacity = 1)

        onMain { AppCoreAndroid.appcoreCreate(CapturingSink()) }
        try {
            val cb = object : ObservationCallback {
                override fun onChange() { capturedLooper.trySend(android.os.Looper.myLooper()) }
            }
            onMain {
                AppCoreAndroid.appcoreObserveGetStoriesJSON(cb)
                AppCoreAndroid.appcoreObserveGetIsLoading(cb)
                AppCoreAndroid.appcoreObserveGetSearchQuery(cb)
                AppCoreAndroid.appcoreObserveGetLastRefreshedAt(cb)
                AppCoreAndroid.appcoreObserveGetLoadError(cb)
            }
            onMain { AppCoreAndroid.appcoreDispatch(REFRESH_JSON) }
            val looper = withTimeout(5_000) { capturedLooper.receive() }
            assertEquals(
                "ObservationCallback.onChange must run on Android's main Looper",
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
            assertEquals("cold-start getter is empty", "",
                onMainResult { AppCoreAndroid.appcoreObserveGetSearchQuery(noOp) })
            onMain { AppCoreAndroid.appcoreSetSearchQuery("hello") }
            assertEquals("getter returns value just set, synchronously", "hello",
                onMainResult { AppCoreAndroid.appcoreObserveGetSearchQuery(noOp) })
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
            assertEquals("rust", onMainResult { AppCoreAndroid.appcoreObserveGetSearchQuery(noOp) })
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
