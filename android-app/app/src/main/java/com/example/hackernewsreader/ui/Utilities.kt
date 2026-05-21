package com.example.hackernewsreader.ui

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SwipeToDismissBoxState
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlin.reflect.KMutableProperty0


/**
 * Bridges a Skip-transpiled Swift `Array<T>` to a Kotlin `List<T>` without copying.
 *
 * Skip's generated bridge declares `Array<Element>.kotlin(nocopy)` as returning
 * `MutableList<*>` — the element type is erased at the JNI boundary, so the cast
 * is required. `nocopy = true` returns the underlying `MutableList` directly,
 * skipping the per-element `.kotlin()` deep-copy that the default performs.
 */
@Suppress("UNCHECKED_CAST")
fun <T> skip.lib.Array<T>.asList(): List<T> = kotlin(nocopy = true) as List<T>

/**
 * A `SwipeToDismissBoxState` that invokes [onSwipe] when the row settles on a
 * non-`Settled` value, then animates the row back.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun rememberSwipeActionState(onSwipe: (SwipeToDismissBoxValue) -> Unit): SwipeToDismissBoxState {
    val state = rememberSwipeToDismissBoxState()
    val latestOnSwipe by rememberUpdatedState(onSwipe)
    LaunchedEffect(state) {
        snapshotFlow { state.currentValue }.collect { value ->
            if (value != SwipeToDismissBoxValue.Settled) {
                latestOnSwipe(value)
                state.reset()
            }
        }
    }
    return state
}

/**
 * Compose equivalent of a SwiftUI `Binding<String>` over a `TextFieldState`:
 * seeds the field from [property], forwards edits to [property]'s setter, and
 * reflects external writes back (cursor jumps to end on reflection).
 */
@Composable
fun rememberBoundTextFieldState(property: KMutableProperty0<String>): TextFieldState {
    val state = rememberTextFieldState(initialText = property.get())
    val current = property.get()
    val latestProperty by rememberUpdatedState(property)
    LaunchedEffect(state) {
        snapshotFlow { state.text.toString() }
            .distinctUntilChanged()
            .collect { if (it != latestProperty.get()) latestProperty.set(it) }
    }
    LaunchedEffect(current) {
        if (state.text.toString() != current) {
            state.setTextAndPlaceCursorAtEnd(current)
        }
    }
    return state
}
