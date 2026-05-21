package com.example.hackernewsreader.ui

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
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
 * Compose equivalent of a SwiftUI `Binding<String>` over a `TextFieldState`.
 *
 * Seeds the field with [property]'s current value on first composition, forwards
 * user edits via [property]'s setter, and reflects external writes to [property]
 * back into the field (cursor jumps to end on reflection).
 *
 * @param property A bound property reference, e.g. `model::searchQuery`. The
 *   Kotlin analogue of SwiftUI's `$model.searchQuery`. Works for any Kotlin
 *   `var`, including Skip-bridged `@Observable` properties whose getter and
 *   setter route through the JNI bridge.
 * @return A remembered `TextFieldState` to pass to `SearchBarDefaults.InputField`
 *   (or any `TextFieldState`-shaped API).
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
