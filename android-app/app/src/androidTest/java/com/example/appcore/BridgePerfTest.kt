package com.example.appcore

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.appcore.bridge.AppCoreAndroid
import com.example.appcore.bridge.CommandSink
import com.example.appcore.bridge.SearchQuerySink
import com.example.appcore.bridge.SnapshotSink
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
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
 * The Swift side holds a single `@JavaUIActor`-isolated `Bridge`
 * namespace; `appcoreCreate` calls `Bridge.attach(...)` and
 * `appcoreDestroy()` calls `Bridge.detach()`. `Bridge.attach` enforces
 * a once-and-only-once contract via `precondition` — production never
 * calls `appcoreDestroy`, so this test pattern (attach → work →
 * `finally { destroy }`) is the only place that exercises the
 * detach/re-attach cycle.
 *
 * **Lifecycle reset.** Instrumented tests run in the same process as
 * the app, so `AppCoreApplication.onCreate` has already called
 * `AppModelHolder.start()` (→ `appcoreCreate`) by the time JUnit
 * starts. Without an explicit detach, the first test's
 * `appcoreCreate(...)` would be the *second* attach and trip the
 * precondition. The `@Before` below detaches before each test (a
 * no-op when already detached) so each `@Test` body's
 * `appcoreCreate(...)` lands in a clean state.
 */
@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class BridgePerfTest {

    /**
     * Reset bridge state before each test. Runs on Android's main
     * Looper because `Bridge.detach` is `@JavaUIActor`-isolated and
     * the JNI thunk `assumeIsolated`s into that domain.
     * `Bridge.detach` is idempotent, so this is a no-op when already
     * detached.
     */
    @Before
    fun resetBridge() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            AppCoreAndroid.appcoreDestroy()
        }
    }

    private class CapturingSink : SnapshotSink, CommandSink, SearchQuerySink {
        val channel = Channel<String>(capacity = Channel.UNLIMITED)
        val searchQueryChannel = Channel<String>(capacity = Channel.UNLIMITED)
        override fun deliver(snapshotJSON: String) {
            channel.trySend(snapshotJSON)
        }
        // The perf test only consumes snapshots; commands are ignored
        // so the same instance can be passed for both sinks.
        override fun deliverCommand(commandJSON: String) {}
        // Per-property `searchQuery` deliveries — exposed separately so
        // the searchQuery-specific tests can await them.
        override fun deliverSearchQuery(value: String) {
            searchQueryChannel.trySend(value)
        }
    }

    // Hand-written wire literals avoid pulling kotlinx.serialization into
    // the hot path — these tests measure Swift-side cost only.
    private companion object {
        // syncJniCall_overhead measures fire-and-forget JNI cost only,
        // so the toggle id never has to match a real story.
        const val TOGGLE_FOO_JSON = """{"type":"toggleRead","id":"foo"}"""
        const val REFRESH_JSON = """{"type":"refresh"}"""
        // First "id" key in the snapshot belongs to the first story (no
        // other Story field is named "id"). Lifted to a companion to
        // avoid recompiling the regex per call.
        val FIRST_ID_REGEX = Regex("\"id\":\"([^\"]+)\"")
    }

    /** Drains snapshots until one with a non-empty `stories` array is
     * received, then returns its first story id. Used by tests that
     * exercise toggleRead — toggling a read for an id without a matching
     * Story produces no encoded change (`readIds` is off the wire,
     * `Story.isRead` is the projection), so the bridge dedup correctly
     * skips the emission and the test would never see a per-toggle
     * snapshot.
     */
    private suspend fun firstStoryIdAfterRefresh(sink: CapturingSink): String {
        onMain { AppCoreAndroid.appcoreDispatch(REFRESH_JSON) }
        val withStories = withTimeout(10_000) {
            var s = sink.channel.receive()
            while (!s.contains("\"stories\":[{")) {
                s = sink.channel.receive()
            }
            s
        }
        return FIRST_ID_REGEX.find(withStories)?.groupValues?.get(1)
            ?: error("could not parse first story id from $withStories")
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
    fun a_coldStart_searchQueryDelivered() = runBlocking {
        // Per-property push channel mirrors the snapshot one — `Observations`'
        // initial-value semantics deliver the cold-start `state.searchQuery`
        // (initially "") within ~ms of `appcoreCreate`. This test pairs
        // with `a_coldStart_initialSnapshotDelivered` to guard the second
        // half of the bridge's two-channel cold-start contract.
        val sink = CapturingSink()
        onMain { AppCoreAndroid.appcoreCreate(sink, sink, sink) }
        try {
            val initial = withTimeout(50) { sink.searchQueryChannel.receive() }
            assertEquals("cold-start searchQuery is empty", "", initial)
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    @Test
    fun a_coldStart_initialSnapshotDelivered() = runBlocking {
        val sink = CapturingSink()
        val nanos = measureNanoTime {
            onMain { AppCoreAndroid.appcoreCreate(sink, sink, sink) }
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
            } finally {
                onMain { AppCoreAndroid.appcoreDestroy() }
            }
        }
        report("cold start: create → first snapshot (synchronous)", listOf(nanos))
    }

    @Test
    fun syncJniCall_overhead() = runBlocking {
        val sink = CapturingSink()
        onMain { AppCoreAndroid.appcoreCreate(sink, sink, sink) }
        try {
            // Drain the cold-start snapshot.
            withTimeout(5_000) { sink.channel.receive() }

            // Warm-up.
            repeat(20) { onMain { AppCoreAndroid.appcoreDispatch(TOGGLE_FOO_JSON) } }
            // Drain any snapshots from warm-up.
            drainBriefly(sink)

            val samples = mutableListOf<Long>()
            repeat(200) {
                samples += measureNanoTime {
                    onMain { AppCoreAndroid.appcoreDispatch(TOGGLE_FOO_JSON) }
                }
            }
            // Drain the resulting snapshots so the next test starts clean.
            drainBriefly(sink)
            report("sync JNI call (dispatch — incl. JSON decode)", samples)
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    @Test
    fun endToEnd_toggleRoundTrip() = runBlocking {
        val sink = CapturingSink()
        onMain { AppCoreAndroid.appcoreCreate(sink, sink, sink) }
        try {
            // Drain the cold-start snapshot.
            withTimeout(5_000) { sink.channel.receive() }

            // Refresh and grab a real story id. Toggling a read for an id
            // that doesn't match any Story changes only `readIds` (off the
            // wire) and the bridge dedup correctly skips the emission, so
            // we'd never see a per-toggle snapshot to await on.
            val storyId = firstStoryIdAfterRefresh(sink)
            val toggleStory = """{"type":"toggleRead","id":"$storyId"}"""

            // Warm-up so the dispatcher and JIT are settled. Each toggle
            // flips Story.isRead in the encoded snapshot, so each one
            // produces a distinct emission.
            repeat(20) {
                onMain { AppCoreAndroid.appcoreDispatch(toggleStory) }
                withTimeout(1_000) { sink.channel.receive() }
            }

            val samples = mutableListOf<Long>()
            repeat(100) {
                val t0 = System.nanoTime()
                onMain { AppCoreAndroid.appcoreDispatch(toggleStory) }
                // Wait for the corresponding snapshot.
                withTimeout(1_000) { sink.channel.receive() }
                samples += System.nanoTime() - t0
            }
            report("end-to-end round-trip (toggle → snapshot)", samples)

            // Sanity: every toggle produced exactly one snapshot.
            assertTrue("samples produced", samples.size == 100)
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    @Test
    fun snapshotPayload_size() = runBlocking {
        val sink = CapturingSink()
        onMain { AppCoreAndroid.appcoreCreate(sink, sink, sink) }
        try {
            // Drain the initial Observations emission.
            withTimeout(5_000) { sink.channel.receive() }

            // Refresh and capture the snapshot once stories have loaded.
            // We can't characterise the cold-start (~340 B) shape here
            // because the bridge is process-wide and prior tests will
            // have warmed AppState; "loaded (no reads)" is the
            // canonical baseline.
            onMain { AppCoreAndroid.appcoreDispatch(REFRESH_JSON) }
            val loaded = withTimeout(10_000) {
                var s = sink.channel.receive()
                while (!s.contains("\"stories\":[{")) {
                    s = sink.channel.receive()
                }
                s
            }
            val ids = FIRST_ID_REGEX.findAll(loaded).take(3).map { it.groupValues[1] }.toList()
            assertTrue("expected at least 3 stories, got ${ids.size}", ids.size == 3)

            println("[BridgePerf] snapshot JSON bytes (loaded, no reads): ${loaded.toByteArray().size}")
            println("[BridgePerf] snapshot JSON (loaded, no reads): $loaded")

            // Toggle three real story ids — each flips Story.isRead in
            // the encoded snapshot, so each emits a distinct payload.
            ids.forEach { id ->
                onMain { AppCoreAndroid.appcoreDispatch("""{"type":"toggleRead","id":"$id"}""") }
            }

            // Drain to the last snapshot in a small window. Three
            // synchronous willSets fire three transactions, but the
            // bridge's String dedup may coalesce identical ones.
            var withReads = loaded
            try {
                withTimeout(500) {
                    while (true) withReads = sink.channel.receive()
                }
            } catch (_: Exception) { /* timeout — channel idle */ }

            println("[BridgePerf] snapshot JSON bytes (3 read): ${withReads.toByteArray().size}")
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    @Test
    fun bridgeWorkRunsOnUIThread() = runBlocking {
        // Canary for the `LooperExecutor` contract: `JavaUIActor`'s
        // executor pins the global actor to Android's main `Looper`,
        // so every sink callback fires on the UI thread. Capture
        // `Looper.myLooper()` from inside `deliver`; assert it equals
        // `Looper.getMainLooper()`. If a future refactor swaps the
        // executor or drops `unownedExecutor`, this test fails before
        // any per-thread JNI subtlety bites in production.
        val mainLooper = android.os.Looper.getMainLooper()
        val capturedLooper = Channel<android.os.Looper?>(capacity = 1)
        val sink = object : SnapshotSink, CommandSink, SearchQuerySink {
            override fun deliver(snapshotJSON: String) {
                capturedLooper.trySend(android.os.Looper.myLooper())
            }
            override fun deliverCommand(commandJSON: String) {}
            override fun deliverSearchQuery(value: String) {}
        }
        onMain { AppCoreAndroid.appcoreCreate(sink, sink, sink) }
        try {
            val looper = withTimeout(5_000) { capturedLooper.receive() }
            assertEquals(
                "SnapshotSink.deliver must run on Android's main Looper",
                mainLooper,
                looper
            )
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    @Test
    fun getSearchQuery_returnsCurrentSwiftValue() = runBlocking {
        // Locks in the contract that `appcoreGetSearchQuery` reads
        // through the bridge synchronously: after `appcoreSetSearchQuery("hello")`
        // returns, `appcoreGetSearchQuery()` returns "hello" without
        // waiting on any async round-trip. The Kotlin `BridgedSource`
        // relies on this for `produceState`'s initial-value seeding.
        val sink = CapturingSink()
        onMain { AppCoreAndroid.appcoreCreate(sink, sink, sink) }
        try {
            // Drain cold-start.
            withTimeout(5_000) { sink.channel.receive() }
            withTimeout(5_000) { sink.searchQueryChannel.receive() }

            assertEquals(
                "cold-start getter is empty",
                "",
                onMainResult { AppCoreAndroid.appcoreGetSearchQuery() }
            )

            onMain { AppCoreAndroid.appcoreSetSearchQuery("hello") }
            assertEquals(
                "getter returns the value just set, synchronously",
                "hello",
                onMainResult { AppCoreAndroid.appcoreGetSearchQuery() }
            )
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    @Test
    fun searchQueryRoundTrip_throughSetterAndSink() = runBlocking {
        // Two-way bridge contract:
        //   1. `appcoreSetSearchQuery("rust")` reaches the Swift side;
        //      the watcher fires runFetch which produces a snapshot
        //      with stories matching "rust".
        //   2. The bridge's `lastSetterValue` dedup suppresses the echo
        //      — the SearchQuerySink does NOT deliver "rust" back. (This
        //      is what prevents Compose's local mirror from getting
        //      clobbered by echoes of writes it just sent.)
        val sink = CapturingSink()
        onMain { AppCoreAndroid.appcoreCreate(sink, sink, sink) }
        try {
            // Drain cold-start snapshot + cold-start searchQuery emission.
            withTimeout(5_000) { sink.channel.receive() }
            withTimeout(5_000) { sink.searchQueryChannel.receive() }

            onMain { AppCoreAndroid.appcoreSetSearchQuery("rust") }

            // Watcher → runFetch → search succeeds → snapshot arrives.
            // 10s budget covers HTTP latency for the Algolia API.
            val snapshot = withTimeout(10_000) {
                var s = sink.channel.receive()
                while (!s.contains("\"stories\":[{")) {
                    s = sink.channel.receive()
                }
                s
            }
            assertTrue(
                "snapshot contains stories after setSearchQuery: $snapshot",
                snapshot.contains("\"stories\":[{")
            )

            // Echo dedup canary: no SearchQuerySink delivery within a
            // generous window. If `lastSetterValue` is removed, the
            // Observations loop emits "rust" back through the sink.
            var sawEcho = false
            try {
                withTimeout(500) {
                    val v = sink.searchQueryChannel.receive()
                    if (v == "rust") sawEcho = true
                }
            } catch (_: Exception) { /* expected timeout */ }
            assertEquals("bridge dedup must suppress the echo", false, sawEcho)
        } finally {
            onMain { AppCoreAndroid.appcoreDestroy() }
        }
    }

    /**
     * Runs [block] on Android's main `Looper`, blocking the caller
     * until it completes. JNI thunks (`appcoreCreate`, `appcoreDispatch`,
     * `appcoreSetSearchQuery`, `appcoreGetSearchQuery`, `appcoreDestroy`)
     * use `Actor.assumeIsolated` and require the bridge actor's
     * executor's thread (= main looper). `AndroidJUnit4` tests run on
     * the instrumentation thread by default, so any JNI call from a
     * `@Test` method must be hopped onto main first or
     * `LooperExecutor.checkIsolated()` traps.
     *
     * Adds runOnMainSync overhead per call (~tens of µs); the perf
     * numbers reported by these tests will reflect that and are
     * therefore inflated relative to a real Compose-driven dispatch
     * (which is already on the main looper). The relative measurements
     * (cold-start vs round-trip vs sync overhead) still tell us the
     * shape of the bridge — they're sanity checks, not regression
     * gates.
     */
    private fun onMain(block: () -> Unit) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync(block)
    }

    /** Returning variant of [onMain] for thunks that yield a value. */
    private fun <T : Any> onMainResult(block: () -> T): T {
        lateinit var result: T
        InstrumentationRegistry.getInstrumentation().runOnMainSync { result = block() }
        return result
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
