package com.example.appcore.state

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import com.example.appcore.bridge.ObservationCallback

private val mainHandler = Handler(Looper.getMainLooper())

/**
 * A Swift `@Observable` property bridged to Kotlin. Construct one in a
 * model holder by passing a fused `appcoreObserveGet*` thunk; convert it
 * to a Compose [State] inside a composable via [asState].
 *
 * Usage:
 * ```kotlin
 * // In the model holder:
 * val stories = SwiftState { cb -> AppCoreAndroid.appcoreObserveGetStoriesHandle(cb)... }
 *
 * // In a Composable:
 * val stories by holder.stories.asState()
 * ```
 *
 * Use [asState] rather than a `@Composable operator fun getValue` extension
 * so reads of the resulting local variable are plain `State<T>.value` reads
 * (not composable calls). This lets the variable be read inside non-composable
 * lambdas such as `LazyListScope.() -> Unit`.
 */
fun interface SwiftState<T> {
    /**
     * Calls a fused Swift `appcoreObserveGet*` thunk: registers [callback]
     * as a one-shot tracker on the read properties and returns the current
     * value.
     */
    fun observe(callback: ObservationCallback): T
}

@Composable
fun <T> SwiftState<T>.asState(): State<T> = rememberSwiftState(this::observe)

/**
 * Remembers a [SwiftBinding] that mirrors the current value of a Swift
 * `@Observable` property and exposes it as a Compose [State].
 *
 * The composable lifetime owns the observation chain — disposal stops the
 * re-arming so Swift's one-shot tracker can drain and the JNI-pinned chain
 * gets reclaimed. See [SwiftBinding] for the willSet-race mechanics.
 */
@Composable
private fun <T> rememberSwiftState(observe: (ObservationCallback) -> T): State<T> {
    val binding = remember { SwiftBinding(observe) }
    DisposableEffect(Unit) { onDispose { binding.dispose() } }
    return binding.state
}

/**
 * Holds the [MutableState] backing a single observation, plus a [dispose]
 * gate that lets the re-arming chain unwind when the composable leaves.
 *
 * **Why [dispose] matters.** Swift's `withObservationTracking` registry
 * holds a JNI global ref to the [ObservationCallback], which captures
 * `this`. Even after Compose drops its `remember`-slot reference, this
 * binding stays pinned by Swift until the registered callback fires and
 * isn't replaced. [dispose] is the signal to *not* replace it: a
 * post-dispose `onChange` posts a no-op, the existing one-shot tracker
 * drains, the global ref is freed, and GC can reclaim the chain.
 *
 * **Why re-registration is deferred via [mainHandler].** Swift's
 * `withObservationTracking` fires `onChange` *inside* the property's
 * `willSet`, before the mutation has committed. A synchronous re-call of
 * [thunk] would re-enter Swift and read the pre-mutation backing storage
 * (the getter still returns the old `_hits` etc. during willSet). Posting
 * the re-registration onto Android's main looper defers it to the next
 * loop iteration — after the writer's setter (and any sibling commits in
 * the same dispatch arm) unwinds — so the recursive read sees the final
 * committed state. The post runs strictly before the next Compose frame,
 * so `state.value` carries the fresh value by recomposition time.
 */
private class SwiftBinding<T>(private val thunk: (ObservationCallback) -> T) {
    private var active = true

    val state: MutableState<T> = mutableStateOf(observe())

    fun dispose() { active = false }

    private fun observe(): T = thunk(ObservationCallback {
        mainHandler.post { if (active) state.value = observe() }
    })
}
