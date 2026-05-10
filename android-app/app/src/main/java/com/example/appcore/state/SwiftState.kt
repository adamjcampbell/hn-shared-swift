package com.example.appcore.state

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import com.example.appcore.bridge.AppCoreAndroid
import com.example.appcore.bridge.OnChange
import org.swift.swiftkit.core.tuple.Tuple2
import java.util.Optional
import kotlin.jvm.optionals.getOrNull

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
 * model holder by passing the matching pair of Swift thunks: an
 * `appcoreObserve*` (registers a long-lived Task and returns a
 * `(token, initialValue)` tuple) and an `appcoreRead*` (reads the
 * current value for re-reads on each emission). Convert it to a Compose
 * [State] inside a composable via [asState].
 *
 * Usage:
 * ```kotlin
 * // In the model holder:
 * val isLoading = SwiftState(
 *     observe = AppCoreAndroid::appcoreObserveIsLoading,
 *     read    = AppCoreAndroid::appcoreReadIsLoading,
 * )
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
     * Registers a long-lived Swift-side observation Task and returns a
     * `(token, initialValue)` tuple. Cancellation tears the Task down
     * and releases the JNI ref to the [OnChange] callback.
     */
    val observe: (OnChange) -> Tuple2<Long, T>,
    /**
     * Reads the current value of the bridged property. Called by the
     * binding's [OnChange] handler on every emission to refresh
     * `MutableState.value`.
     */
    val read: () -> T,
) {
    companion object {
        /**
         * Adapter for thunks whose initial-value tuple slot is
         * `Optional<T>` (the shape jextract generates for Swift `T?`)
         * and whose read returns `Optional<T>`. Unwraps both to a Kotlin
         * nullable `T?` so model holders can use method-reference syntax
         * for nullable fields the same way as non-null ones:
         *
         * ```kotlin
         * val lastRefreshed = SwiftState.ofNullable(
         *     observe = AppCoreAndroid::appcoreObserveLastRefreshedAt,
         *     read    = AppCoreAndroid::appcoreReadLastRefreshedAt,
         * )
         * ```
         */
        fun <T : Any> ofNullable(
            observe: (OnChange) -> Tuple2<Long, Optional<T>>,
            read: () -> Optional<T>,
        ): SwiftState<T?> = SwiftState(
            observe = { onChange ->
                val (token, initial) = observe(onChange)
                Tuple2(token, initial.getOrNull())
            },
            read = { read().getOrNull() },
        )
    }
}

@Composable
fun <T> SwiftState<T>.asState(): State<T> = rememberSwiftState(this)

/**
 * Remembers a [SwiftBinding] that mirrors the current value of a Swift
 * `@Observable` property and exposes it as a Compose [State]. Disposal
 * cancels the Swift-side observation Task so the JNI-pinned chain is
 * reclaimed immediately rather than waiting for the next mutation to
 * drain a one-shot tracker.
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
 * a `(token, initialValue)` tuple — the token is stored for cancellation
 * and the initial value seeds [state]. One round-trip delivers both.
 *
 * **Per emission.** Swift's [OnChange] callback fires; the handler reads
 * the current value via [SwiftState.read] and writes it to [state].
 *
 * **Dispose.** Hands the token back to Swift, which cancels the Task —
 * the for-await loop exits, the OnChange capture is released, the JNI
 * global ref drops, and GC reclaims the chain. No "leak until next
 * mutation" window.
 *
 * **Synchronous re-read is safe.** Swift's `Observations` AsyncSequence
 * emits at transaction end (post-didSet), not inside willSet, so by the
 * time `OnChange.onChange` fires the mutation has committed. The read
 * call inside the callback returns post-mutation state directly.
 */
private class SwiftBinding<T>(swiftState: SwiftState<T>) {
    private val read = swiftState.read

    val state: MutableState<T>
    private val token: Long

    init {
        val (capturedToken, initial) = swiftState.observe(OnChange { state.value = read() })
        token = capturedToken
        state = mutableStateOf(initial)
    }

    fun dispose() {
        AppCoreAndroid.appcoreCancelObservation(token)
    }
}
