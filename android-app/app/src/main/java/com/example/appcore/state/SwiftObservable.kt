package com.example.appcore.state

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import com.example.appcore.bridge.ObservationCallback

/**
 * Reads a value from a Swift @Observable model with per-property Compose
 * reactivity. [observe] receives a one-shot [ObservationCallback] and must
 * call the fused Swift `appcoreObserveGet*` thunk, which atomically registers
 * a per-property dependency AND returns the current value via
 * `withObservationTracking`'s apply-closure return.
 *
 * The value is held in a [MutableState]. When [ObservationCallback.onChange]
 * fires (synchronously on the UI thread via JavaUIActor.assumeIsolated),
 * [observe] is called immediately — re-registering the Swift tracking scope
 * and writing the fresh value to the state in one step, closing the observation
 * gap that would otherwise exist between onChange and the next recompose.
 * Compose skips recomposition if the new value is structurally equal to the
 * current one.
 *
 * Initialisation runs inside the [remember] computation block so that the
 * first composition always reads a non-null (real) value. The [DisposableEffect]
 * stops the observation loop when the composable leaves the composition.
 */
@Composable
fun <T> rememberSwiftObserved(observe: (ObservationCallback) -> T): State<T> {
    val handle = remember {
        ObservationHandle(mutableStateOf<Any?>(null)).also { it.start(observe) }
    }
    DisposableEffect(Unit) { onDispose { handle.active = false } }
    @Suppress("UNCHECKED_CAST")
    return handle.state as State<T>
}

private class ObservationHandle(val state: MutableState<Any?>) {
    var active = true

    fun <T> start(observe: (ObservationCallback) -> T) {
        state.value = observe(object : ObservationCallback {
            override fun onChange() { if (active) start(observe) }
        })
    }
}

/**
 * A holder for a single Swift @Observable property that can be read with the
 * `by` operator inside a `@Composable` function. Backed by [rememberSwiftObserved].
 *
 * Usage:
 * ```kotlin
 * // In the model holder:
 * val stories = BridgedProperty { cb -> observeGetStories(cb) }
 *
 * // In a Composable:
 * val stories by holder.stories.asState()
 * ```
 *
 * Use [asState] rather than a `@Composable operator fun getValue` extension so
 * that reads of the resulting local variable are plain `State<T>.value` reads
 * (not composable calls). This lets the variable be read inside non-composable
 * lambdas such as `LazyListScope.() -> Unit`.
 */
class BridgedProperty<T>(val observe: (ObservationCallback) -> T)

@Composable
fun <T> BridgedProperty<T>.asState(): State<T> = rememberSwiftObserved(observe)
