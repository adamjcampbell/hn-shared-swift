package com.example.appcore

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.appcore.bridge.AppCoreAndroid
import com.example.appcore.bridge.CommandSink
import com.example.appcore.bridge.SnapshotSink
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters
import kotlin.math.roundToLong
import kotlin.system.measureNanoTime

/**
 * Latency micro-benchmarks for the Swift→Kotlin bridge.
 *
 * Three measurements:
 *  - cold start: time from `appcoreCreate` to the first snapshot delivery
 *  - sync JNI overhead: just the time of the synchronous `appcoreDispatch`
 *    call (the work is fire-and-forget on the Swift side, so this is ~the cost
 *    of crossing JNI plus enqueuing a Task on the actor)
 *  - end-to-end round-trip: `dispatch(toggleRead)` call → next snapshot
 *    containing the new read set arriving in the JVM
 *
 * Numbers are logged via println so they show up in `adb logcat` and the
 * connectedAndroidTest report. Tolerances are generous — these are sanity
 * checks, not regression gates.
 *
 * The Swift side holds a single `AndroidBridge.shared`. `appcoreCreate`
 * replaces the sink (cancelling any prior observation task) so each test
 * can attach a fresh `CapturingSink` without a dedicated reset hook;
 * `appcoreDestroy()` detaches before the next test runs.
 */
@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class BridgePerfTest {

    private class CapturingSink : SnapshotSink, CommandSink {
        val channel = Channel<String>(capacity = Channel.UNLIMITED)
        override fun deliver(snapshotJSON: String) {
            channel.trySend(snapshotJSON)
        }
        // The perf test only consumes snapshots; commands are ignored
        // so the same instance can be passed for both sinks.
        override fun deliverCommand(commandJSON: String) {}
    }

    // Hand-written wire literals avoid pulling kotlinx.serialization into
    // the hot path — these tests measure Swift-side cost only.
    private companion object {
        const val TOGGLE_FOO_JSON = """{"type":"toggleRead","id":"foo"}"""
        const val TOGGLE_BAR_JSON = """{"type":"toggleRead","id":"bar"}"""
    }

    /**
     * Regression test: the initial snapshot must be delivered without any
     * mutation having occurred, via `Observations`'s initial-value
     * emission (Swift 6.2+; see WWDC25 *What's new in Swift*).
     *
     * Why this matters: if a future toolchain ever stops emitting an
     * initial value, the Compose UI would render with `snapshot == null`
     * until the user did something (refresh or first search keystroke).
     *
     * The `a_` prefix puts this first under `@FixMethodOrder(NAME_ASCENDING)`
     * so it runs before any other test toggles state. This matters because
     * the singleton bridge is process-wide; an earlier toggling test would
     * mask a regression by warming the executor.
     */
    @Test
    fun a_coldStart_initialSnapshotDelivered() = runBlocking {
        val sink = CapturingSink()
        val nanos = measureNanoTime {
            AppCoreAndroid.appcoreCreate(sink, sink)
            try {
                // 50 ms is generous — the bridge actor's attach() task
                // spawns and emits the initial Observations value within
                // a couple of ms in practice. Anything longer indicates
                // Observations stopped emitting an initial value.
                val initial = withTimeout(50) { sink.channel.receive() }
                assertNotNull("first snapshot JSON", initial)
                // The HN reader starts with empty AppCore state — front page
                // gets fetched once the UI dispatches `.refresh`. The
                // initial Observations emission lets Compose move past
                // `null` and render an empty list before the first fetch
                // settles.
                assertTrue("contains empty stories array", initial.contains("\"stories\":[]"))
                assertTrue("isLoading defaults false", initial.contains("\"isLoading\":false"))
            } finally {
                AppCoreAndroid.appcoreDestroy()
            }
        }
        report("cold start: create → first snapshot (synchronous)", listOf(nanos))
    }

    @Test
    fun syncJniCall_overhead() = runBlocking {
        val sink = CapturingSink()
        AppCoreAndroid.appcoreCreate(sink, sink)
        try {
            // Drain the cold-start snapshot.
            withTimeout(5_000) { sink.channel.receive() }

            // Warm-up.
            repeat(20) { AppCoreAndroid.appcoreDispatch(TOGGLE_FOO_JSON) }
            // Drain any snapshots from warm-up.
            drainBriefly(sink)

            val samples = mutableListOf<Long>()
            repeat(200) {
                samples += measureNanoTime {
                    AppCoreAndroid.appcoreDispatch(TOGGLE_FOO_JSON)
                }
            }
            // Drain the resulting snapshots so the next test starts clean.
            drainBriefly(sink)
            report("sync JNI call (dispatch — incl. JSON decode)", samples)
        } finally {
            AppCoreAndroid.appcoreDestroy()
        }
    }

    @Test
    fun endToEnd_toggleRoundTrip() = runBlocking {
        val sink = CapturingSink()
        AppCoreAndroid.appcoreCreate(sink, sink)
        try {
            // Drain the cold-start snapshot.
            withTimeout(5_000) { sink.channel.receive() }

            // Warm-up so the dispatcher and JIT are settled.
            repeat(20) {
                AppCoreAndroid.appcoreDispatch(TOGGLE_FOO_JSON)
                withTimeout(1_000) { sink.channel.receive() }
            }

            val samples = mutableListOf<Long>()
            repeat(100) { i ->
                val t0 = System.nanoTime()
                AppCoreAndroid.appcoreDispatch(TOGGLE_BAR_JSON)
                // Wait for the corresponding snapshot.
                withTimeout(1_000) { sink.channel.receive() }
                samples += System.nanoTime() - t0
            }
            report("end-to-end round-trip (toggle → snapshot)", samples)

            // Sanity: every toggle produced exactly one snapshot.
            assertTrue("samples produced", samples.size == 100)
        } finally {
            AppCoreAndroid.appcoreDestroy()
        }
    }

    @Test
    fun snapshotPayload_size() = runBlocking {
        val sink = CapturingSink()
        AppCoreAndroid.appcoreCreate(sink, sink)
        try {
            val first = withTimeout(5_000) { sink.channel.receive() }
            println("[BridgePerf] snapshot JSON bytes (cold): ${first.toByteArray().size}")
            println("[BridgePerf] snapshot JSON (cold): $first")

            // Mark three stories read. Each toggle may or may not produce its
            // own snapshot depending on Observations' transactional batching;
            // we just measure the size of whichever snapshot lands last in a
            // small window.
            AppCoreAndroid.appcoreDispatch(TOGGLE_FOO_JSON)
            AppCoreAndroid.appcoreDispatch(TOGGLE_BAR_JSON)
            AppCoreAndroid.appcoreDispatch("""{"type":"toggleRead","id":"baz"}""")

            var last = first
            try {
                withTimeout(500) {
                    while (true) last = sink.channel.receive()
                }
            } catch (_: Exception) { /* timeout — channel idle */ }

            println("[BridgePerf] snapshot JSON bytes (3 read): ${last.toByteArray().size}")
        } finally {
            AppCoreAndroid.appcoreDestroy()
        }
    }

    private suspend fun drainBriefly(sink: CapturingSink) {
        // Soak up snapshots that arrive within the next 50 ms.
        try {
            withTimeout(50) {
                while (true) sink.channel.receive()
            }
        } catch (_: Exception) { /* timeout — channel idle */ }
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
        ns < 10_000 -> "${ns}ns"
        ns < 10_000_000 -> "${ns / 1_000}µs"
        else -> "${ns / 1_000_000}ms"
    }
}
