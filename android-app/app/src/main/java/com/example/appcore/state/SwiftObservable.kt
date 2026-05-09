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
 * Reads a value from a Swift @Observable model with per-property Compose
 * reactivity. [observe] receives a one-shot [ObservationCallback] and must
 * call the fused Swift `appcoreObserveGet*` thunk, which atomically registers
 * a per-property dependency AND returns the current value via
 * `withObservationTracking`'s apply-closure return.
 *
 * **Re-registration is deferred via `Handler.post`.** Swift's
 * `withObservationTracking` fires `onChange` *inside* the property's
 * `willSet`, before the mutation has committed. A synchronous re-call
 * of [observe] would re-enter Swift and read the pre-mutation backing
 * storage (the getter still returns the old `_hits` etc. during
 * willSet). Posting the re-registration onto Android's main looper
 * defers it to the next loop iteration — after the writer's setter
 * (and any sibling commits in the same dispatch arm) unwinds — so the
 * recursive read sees the final committed state. The post runs strictly
 * before the next Compose frame, so `state.value` carries the fresh
 * value by recomposition time.
 *
 * The value is held in a [MutableState]; Compose skips recomposition
 * if the new value is structurally equal to the current one.
 *
 * Initialisation runs inside the [remember] computation block so that the
 * first composition always reads a non-null (real) value. The
 * [DisposableEffect] flips `active = false` when the composable leaves
 * the composition; the `if (active)` guard inside the posted lambda
 * makes any in-flight onChange a no-op past disposal.
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
            override fun onChange() {
                if (!active) return
                mainHandler.post { if (active) start(observe) }
            }
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
