package com.example.appcore.state

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import com.example.appcore.bridge.OnChange
import java.util.Optional
import kotlin.jvm.optionals.getOrNull

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
    fun observe(callback: OnChange): T

    companion object {
        /**
         * Adapter for thunks that return `Optional<T>` — the shape jextract
         * generates for Swift `T?` returns. Unwraps to a Kotlin nullable
         * `T?` so model holders can use method-reference syntax for
         * nullable fields the same way as non-null ones:
         *
         * ```kotlin
         * val isLoading      = SwiftState(AppCoreAndroid::appcoreObserveGetIsLoading)
         * val lastRefreshed  = SwiftState.ofNullable(AppCoreAndroid::appcoreObserveGetLastRefreshedAt)
         * ```
         *
         * Modelled on `Optional.ofNullable` — a static factory that lifts
         * a presence-or-absence value into a containing type.
         */
        fun <T : Any> ofNullable(track: (OnChange) -> Optional<T>): SwiftState<T?> =
            SwiftState { cb -> track(cb).getOrNull() }
    }
}

@Composable
fun <T> SwiftState<T>.asState(): State<T> = rememberSwiftState(this::observe)

/**
 * Remembers a [SwiftBinding] that mirrors the current value of a Swift
 * `@Observable` property and exposes it as a Compose [State].
 *
 * The composable lifetime owns the observation chain — disposal stops the
 * re-arming so Swift's one-shot tracker can drain and the JNI-pinned chain
 * gets reclaimed. See [SwiftBinding] for the lifetime mechanics.
 */
@Composable
private fun <T> rememberSwiftState(observe: (OnChange) -> T): State<T> {
    val binding = remember { SwiftBinding(observe) }
    DisposableEffect(Unit) { onDispose { binding.dispose() } }
    return binding.state
}

/**
 * Holds the [MutableState] backing a single observation, plus a [dispose]
 * gate that lets the re-arming chain unwind when the composable leaves.
 *
 * **Why [dispose] matters.** Swift's `Observations` registry holds a JNI
 * global ref to the [OnChange], which captures `this`. Even after
 * Compose drops its `remember`-slot reference, this binding stays pinned
 * by Swift until the registered callback fires and isn't replaced.
 * [dispose] is the signal to *not* replace it: a post-dispose `onChange`
 * runs `if (active)` and skips, the existing one-shot tracker drains,
 * the global ref is freed, and GC can reclaim the chain.
 *
 * **Re-registration is synchronous.** Swift's `Observations` AsyncSequence
 * emits at *transaction end* (after the property's didSet), not inside
 * willSet, so by the time `OnChange.onChange` fires the mutation has
 * committed. The recursive re-call of [track] reads post-mutation state
 * directly — no `Handler.post` deferral needed. See `observeGet` in
 * `AppCoreNative.swift` for the Swift-side mechanism.
 */
private class SwiftBinding<T>(private val track: (OnChange) -> T) {
    private var active = true

    val state: MutableState<T> = mutableStateOf(observe())

    fun dispose() { active = false }

    private fun observe(): T = track(OnChange {
        if (active) state.value = observe()
    })
}
