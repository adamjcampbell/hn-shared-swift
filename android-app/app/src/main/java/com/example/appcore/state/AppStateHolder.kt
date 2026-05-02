package com.example.appcore.state

import androidx.compose.runtime.*
import com.example.appcore.native.AppCoreNative
import kotlinx.coroutines.delay
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class City(val id: String, val name: String, val country: String)

@Serializable
data class Snapshot(
    val cities: List<City>,
    val favorites: Set<String>,
    val globalFavoriteCount: Int,
    val lastRefreshedAt: String? = null
)

/**
 * Compose-friendly state holder for AppState.
 *
 * - `snapshot` is a Compose MutableState. Reading it from a composable
 *   subscribes that composable to recomposition on change.
 * - Mutation methods (`toggleFavorite`, `refresh`) call into JNI, which
 *   is fire-and-forget on the Swift side. The result arrives via the
 *   JNI callback, which calls `onSnapshot` and updates `snapshot`.
 */
class AppStateHolder {
    private val handle: Long
    var snapshot by mutableStateOf<Snapshot?>(null)
        private set
    var isRefreshing by mutableStateOf(false)
        private set

    init {
        handle = AppCoreNative.create(
            sinkObj = this,
            sinkMethodName = "onSnapshot",
            sinkMethodSig = "(Ljava/lang/String;)V"
        )
    }

    /** Called from Swift via JNI on every Observations transaction. */
    @Suppress("unused")  // called by JNI
    fun onSnapshot(json: String) {
        snapshot = Json.decodeFromString<Snapshot>(json)
    }

    fun toggleFavorite(id: String) {
        AppCoreNative.toggleFavorite(handle, id)
    }

    suspend fun refresh() {
        isRefreshing = true
        AppCoreNative.refresh(handle)
        // Spinner UX: hold the spinner ~1.1s to roughly match the Swift
        // sleep duration. The actual snapshot arrives independently via
        // onSnapshot. Decoupling the spinner from the snapshot is simpler
        // than threading "refresh complete" back through JNI.
        delay(1100)
        isRefreshing = false
    }

    fun close() {
        AppCoreNative.destroy(handle)
    }
}

@Composable
fun rememberAppState(): AppStateHolder {
    val holder = remember { AppStateHolder() }
    DisposableEffect(holder) { onDispose { holder.close() } }
    return holder
}
