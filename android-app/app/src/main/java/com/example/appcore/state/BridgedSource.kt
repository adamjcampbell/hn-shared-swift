package com.example.appcore.state

import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import java.util.concurrent.CopyOnWriteArrayList

/**
 * A platform-bridged primitive exposed as a Compose-friendly state.
 *
 * No Kotlin-side mirror: [current] reads through JNI on every access,
 * so the Swift bridge actor's value is the single source of truth.
 * Two paths feed Compose state through this wrapper:
 *
 *   1. [set] — Compose-side write. Calls [writeThrough] (the JNI
 *      setter, sync via `Actor.assumeIsolated`) and returns. Listeners
 *      are NOT notified locally — the Swift bridge's `lastSetterValue`
 *      echo dedup suppresses the round-trip back through [deliver],
 *      and Compose's authoritative typing buffer (TextFieldState)
 *      already owns the in-progress text. The Compose [State] produced
 *      by [asState] therefore only reflects out-of-band Swift writes
 *      (cold-start initial + future programmatic clears), which is
 *      what `authoritativeSearchQuery` is conceptually for.
 *   2. [deliver] — push from the platform (cold-start initial +
 *      programmatic Swift writes). Notifies all registered listeners
 *      so the [State] from [asState] updates. Echoes of [set]-originated
 *      writes are filtered on the Swift bridge actor's `lastSetterValue`
 *      dedup before reaching here.
 *
 * Listeners use [CopyOnWriteArrayList] for defence-in-depth: the bridge
 * pins callbacks to the UI thread today (via `LooperExecutor`), but the
 * COW list keeps `addListener`/`removeListener` correct even if a
 * future change re-introduces off-UI deliveries.
 */
class BridgedSource<T>(
    private val readThrough: () -> T,
    private val writeThrough: (T) -> Unit,
) {
    /**
     * Latest value, read through JNI on every access. Used by [asState]'s
     * `produceState(initialValue = …)`, which evaluates this once per
     * composition.
     */
    val current: T get() = readThrough()

    private val listeners = CopyOnWriteArrayList<(T) -> Unit>()

    /** Compose-side write: sync JNI. See class doc for why no local notify. */
    fun set(value: T) {
        writeThrough(value)
    }

    /**
     * Bridge-side push: cold-start initial + programmatic Swift writes.
     * Echoes of [set]-originated writes are filtered on the Swift side
     * (`lastSetterValue` on `AndroidBridge`), so by the time this fires
     * the value is genuinely new.
     */
    fun deliver(value: T) {
        listeners.forEach { it(value) }
    }

    fun addListener(listener: (T) -> Unit): () -> Unit {
        listeners.add(listener)
        return { listeners.remove(listener) }
    }
}

/**
 * Project [BridgedSource] as a read-only Compose [State]. The producer
 * registers a listener for the lifetime of the call site; on dispose
 * (recomposition leaving) the listener is removed. Initial value is
 * read synchronously through JNI via [BridgedSource.current].
 */
@Composable
fun <T> BridgedSource<T>.asState(): State<T> = produceState(initialValue = current) {
    val unregister = addListener { newValue -> value = newValue }
    awaitDispose { unregister() }
}

/**
 * Project [BridgedSource] as a [MutableState]. Reads come from
 * [asState]; writes go through [BridgedSource.set] (sync JNI).
 */
@Composable
fun <T> BridgedSource<T>.asMutableState(): MutableState<T> {
    val state = asState()
    return remember(state) { MutableStateAdapter(state, ::set) }
}

/**
 * Combines a read-only [State] with a write callback to satisfy
 * Compose's [MutableState] interface. Used by [BridgedSource.asMutableState]
 * and reusable for any "read state + write callback" pair.
 *
 * The setter does NOT touch the underlying State directly — it relies
 * on the write callback to drive the listener that updates the State.
 * For [BridgedSource] specifically, that's the [BridgedSource.deliver]
 * path triggered by Swift's out-of-band writes.
 */
class MutableStateAdapter<T>(
    private val state: State<T>,
    private val mutate: (T) -> Unit,
) : MutableState<T> {
    override var value: T
        get() = state.value
        set(value) { mutate(value) }
    override fun component1(): T = value
    override fun component2(): (T) -> Unit = { value = it }
}
