package com.example.appcore.state

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import com.example.appcore.bridge.AppCoreAndroid
import com.example.appcore.bridge.OnChange
import java.util.Optional
import kotlin.jvm.optionals.getOrNull

/**
 * A Swift `@Observable` property bridged to Kotlin. Construct one in a
 * model holder by passing the matching pair of Swift thunks: an
 * `appcoreObserve*` (registers a long-lived Task and returns a token)
 * and an `appcoreRead*` (reads the current value). Convert it to a
 * Compose [State] inside a composable via [asState].
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
     * Registers a long-lived Swift-side observation Task and returns its
     * cancellation token. The Task fires the [OnChange] callback on every
     * mutation; cancellation tears it down immediately and releases the
     * JNI ref to the callback.
     */
    val observe: (OnChange) -> Long,
    /**
     * Reads the current value of the bridged property. Called once for the
     * initial state and once per [OnChange] firing.
     */
    val read: () -> T,
) {
    companion object {
        /**
         * Adapter for `read` thunks that return `Optional<T>` — the shape
         * jextract generates for Swift `T?` returns. Unwraps to a Kotlin
         * nullable `T?` so model holders can use method-reference syntax
         * for nullable fields the same way as non-null ones:
         *
         * ```kotlin
         * val lastRefreshed = SwiftState.ofNullable(
         *     observe = AppCoreAndroid::appcoreObserveLastRefreshedAt,
         *     read    = AppCoreAndroid::appcoreReadLastRefreshedAt,
         * )
         * ```
         *
         * Modelled on `Optional.ofNullable` — a static factory that lifts
         * a presence-or-absence value into a containing type.
         */
        fun <T : Any> ofNullable(
            observe: (OnChange) -> Long,
            read: () -> Optional<T>,
        ): SwiftState<T?> = SwiftState(
            observe = observe,
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
 * **Lifecycle.** The constructor reads the initial value, registers the
 * observation Task on the Swift side, and stores the token. On every
 * subsequent emission the [OnChange] callback re-reads via [SwiftState.read]
 * and writes the fresh value to [state]. On [dispose] we hand the token
 * back to Swift, which cancels the Task — the for-await loop exits, the
 * OnChange capture is released, the JNI global ref drops, and GC reclaims
 * the chain. No "leak until next mutation" window.
 *
 * **Synchronous re-read is safe.** Swift's `Observations` AsyncSequence
 * emits at transaction end (post-didSet), not inside willSet, so by the
 * time `OnChange.onChange` fires the mutation has committed. The read
 * call inside the callback returns post-mutation state directly.
 */
private class SwiftBinding<T>(swiftState: SwiftState<T>) {
    private val read = swiftState.read

    val state: MutableState<T> = mutableStateOf(read())

    private val token: Long = swiftState.observe(OnChange {
        state.value = read()
    })

    fun dispose() {
        AppCoreAndroid.appcoreCancelObservation(token)
    }
}
