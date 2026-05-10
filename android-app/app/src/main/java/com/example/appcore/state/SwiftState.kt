package com.example.appcore.state

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import com.example.appcore.bridge.AppCoreAndroid
import org.swift.swiftkit.core.tuple.Tuple2

/**
 * Destructuring components for the swift-java [Tuple2] wrapper. jextract
 * emits Swift `(A, B)` returns as `Tuple2<A, B>` with public final
 * fields `$0` and `$1`. These extensions let Kotlin call sites destructure
 * with the standard `val (a, b) = tuple` syntax.
 */
operator fun <A, B> Tuple2<A, B>.component1(): A = `$0`
operator fun <A, B> Tuple2<A, B>.component2(): B = `$1`

/**
 * A Swift `@Observable` property bridged to Kotlin. Construct one in a
 * model holder by passing an [observe] lambda that registers a Swift
 * `appcoreObserve*` thunk and adapts the typed `*OnChange` callback to
 * a generic `(T) -> Unit` handler. Convert it to a Compose [State]
 * inside a composable via [asState].
 *
 * Usage:
 * ```kotlin
 * // In the model holder:
 * val isLoading = SwiftState<Boolean>(observe = { handler ->
 *     AppCoreAndroid.appcoreObserveIsLoading(BoolOnChange { handler(it) })
 * })
 *
 * // In a Composable:
 * val isLoading by holder.isLoading.asState()
 * ```
 *
 * Use [asState] rather than a `@Composable operator fun getValue` extension
 * so reads of the resulting local variable are plain `State<T>.value` reads
 * (not composable calls). This lets the variable be read inside non-composable
 * lambdas such as `LazyListScope.() -> Unit`.
 */
class SwiftState<T>(
    /**
     * Registers a long-lived Swift-side observation Task. The supplied
     * `(T) -> Unit` handler is called once per emission with the new
     * post-mutation value. Returns `(token, initialValue)` — the
     * cancellation token plus the value at registration time.
     *
     * Implementations adapt from a typed Swift `*OnChange` protocol
     * (`BoolOnChange`, `StringOnChange`, etc.) to the generic handler.
     */
    val observe: ((T) -> Unit) -> Tuple2<Long, T>,
)

@Composable
fun <T> SwiftState<T>.asState(): State<T> = rememberSwiftState(this)

/**
 * Remembers a [SwiftBinding] that mirrors the current value of a Swift
 * `@Observable` property and exposes it as a Compose [State]. Disposal
 * cancels the Swift-side observation Task so the JNI-pinned chain is
 * reclaimed immediately.
 */
@Composable
private fun <T> rememberSwiftState(swiftState: SwiftState<T>): State<T> {
    val binding = remember { SwiftBinding(swiftState) }
    DisposableEffect(Unit) { onDispose { binding.dispose() } }
    return binding.state
}

/**
 * Holds the [MutableState] backing a single observation, plus the
 * cancellation token returned by Swift's `appcoreObserve*` thunk.
 *
 * **Construction.** Calls [SwiftState.observe] once. The thunk returns
 * `(token, initialValue)` and registers a Swift-side handler that
 * writes each subsequent emission directly to [state] — no separate
 * Kotlin → Swift read on per emission.
 *
 * **Per emission.** The Swift Task fires the typed `*OnChange` callback
 * with the new value; the adapter lambda inside [SwiftState.observe]
 * invokes our handler, which writes [state.value] = newValue. One
 * S→K thunk per emission; no return trip.
 *
 * **Dispose.** Hands the token back to Swift, which cancels the Task —
 * the for-await loop exits, the OnChange capture is released, the JNI
 * global ref drops, and GC reclaims the chain.
 */
private class SwiftBinding<T>(swiftState: SwiftState<T>) {
    val state: MutableState<T>
    private val token: Long

    init {
        val (capturedToken, initial) = swiftState.observe { value ->
            state.value = value
        }
        token = capturedToken
        state = mutableStateOf(initial)
    }

    fun dispose() {
        AppCoreAndroid.appcoreCancelTask(token)
    }
}
