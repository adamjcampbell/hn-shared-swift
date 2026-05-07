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
 * Two write paths feed it:
 *   1. [set] — Compose-side write. Updates [current] synchronously,
 *      calls [writeThrough] (the JNI setter), and notifies listeners.
 *   2. [deliverFromBridge] — push from the platform (cold-start initial
 *      + programmatic Swift writes). Updates [current] and notifies
 *      listeners; echoes of [set]-originated writes are filtered on the
 *      bridge actor (`lastSetterValue` dedup) before reaching here.
 *
 * [current] is updated synchronously on the local-write path so any
 * Compose State produced from [asState] reflects user typing
 * immediately, even though the bridge dedup absorbs the round-trip
 * echo. This is "trust boundary dedup" applied symmetrically: Swift
 * dedups what crosses JNI; Kotlin dedups within Compose.
 *
 * Listeners use [CopyOnWriteArrayList] because [deliverFromBridge] is
 * called from the JNI thread while [addListener] / unregister happen
 * on the main thread (Compose's Composable scope).
 */
class BridgedSource<T>(
    initial: T,
    private val writeThrough: (T) -> Unit,
) {
    @Volatile
    var current: T = initial
        private set

    private val listeners = CopyOnWriteArrayList<(T) -> Unit>()

    /** Compose-side write: optimistic local update + write-through. */
    fun set(value: T) {
        if (current == value) return
        current = value
        writeThrough(value)
        notifyListeners(value)
    }

    /**
     * Bridge-side push: cold-start initial + programmatic Swift writes.
     * Echoes of [set]-originated writes are filtered on the Swift side
     * (`lastSetterValue` on `AndroidBridge`), so by the time this fires
     * the value is genuinely new.
     */
    fun deliverFromBridge(value: T) {
        if (current == value) return
        current = value
        notifyListeners(value)
    }

    fun addListener(listener: (T) -> Unit): () -> Unit {
        listeners.add(listener)
        return { listeners.remove(listener) }
    }

    private fun notifyListeners(value: T) {
        listeners.forEach { it(value) }
    }
}

/**
 * Project [BridgedSource] as a read-only Compose [State]. The producer
 * registers a listener for the lifetime of the call site; on dispose
 * (recomposition leaving) the listener is removed.
 */
@Composable
fun <T> BridgedSource<T>.asState(): State<T> = produceState(initialValue = current) {
    val unregister = addListener { newValue -> value = newValue }
    awaitDispose { unregister() }
}

/**
 * Project [BridgedSource] as a [MutableState]. Reads come from
 * [asState]; writes go through [BridgedSource.set] (which updates
 * `current` synchronously, fires the JNI setter, and notifies
 * listeners — feeding the State).
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
 * on the write callback to invoke the listener that drives the State.
 * For [BridgedSource] specifically, that's the synchronous
 * `notifyListeners` inside `set`.
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
