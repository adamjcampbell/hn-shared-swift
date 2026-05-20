package com.example.hackernewsreader.ui

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
