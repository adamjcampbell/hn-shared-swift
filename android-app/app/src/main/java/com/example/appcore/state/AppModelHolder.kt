package com.example.appcore.state

import com.example.appcore.bridge.AndroidCompletion
import com.example.appcore.bridge.AppCoreAndroid
import com.example.appcore.bridge.CommandSink
import com.example.appcore.bridge.ObservationCallback
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class Story(
    val id: String,
    val title: String,
    val author: String,
    val points: Int,
    val commentCount: Int,
    val url: String? = null,
    val createdAt: String,
    val isRead: Boolean = false,
)

/**
 * Mirrors the Swift `AppEvent` enum. Wire shape is `{"type":"...", ...}`,
 * matching `AppCore/Sources/AppCore/AppEvent.swift`'s `@Codable` +
 * `@CodedAt("type")` MetaCodable annotations.
 */
@Serializable
sealed class AppEvent {
    @Serializable
    @SerialName("toggleRead")
    data class ToggleRead(val id: String) : AppEvent()

    @Serializable
    @SerialName("openStory")
    data class OpenStory(val id: String) : AppEvent()

    @Serializable
    @SerialName("refresh")
    data object Refresh : AppEvent()
}

/**
 * Mirrors the Swift `AppCommand` enum — the Core → UI direction. Wire
 * shape is `{"type":"...", ...}`, matching `AppCommand.swift`.
 */
@Serializable
sealed class AppCommand {
    @Serializable
    @SerialName("presentURL")
    data class PresentURL(val value: String) : AppCommand()
}

/**
 * Process-wide holder for the Swift AppModel bridge.
 *
 * Implements [CommandSink] only — the observation-scope pattern replaces
 * the old push-based snapshot/binding sinks. Each Kotlin composable opens
 * its own scope via `rememberSwiftObserved`, reading exactly the Swift
 * properties it needs. Swift fires `onChange` only for those specific
 * properties, so recomposition is per-composable and per-property.
 */
object AppModelHolder : CommandSink {
    private val json = Json {
        classDiscriminator = "type"
        ignoreUnknownKeys = true
    }

    /**
     * One-shot commands from the Swift core to the UI. Buffered so
     * cold-start emissions are not dropped before the screen collector
     * attaches.
     */
    private val _commands = Channel<AppCommand>(capacity = Channel.BUFFERED)
    val commands: Flow<AppCommand> get() = _commands.receiveAsFlow()

    fun start() {
        AppCoreAndroid.appcoreCreate(this)
    }

    /** Called from Swift via JNI on every yield from `AppModel.commands`. */
    override fun deliverCommand(commandJSON: String) {
        val command = json.decodeFromString<AppCommand>(commandJSON)
        _commands.trySend(command)
    }

    fun setSearchQuery(value: String) =
        AppCoreAndroid.appcoreSetSearchQuery(value)

    // MARK: - Fused observe+read wrappers
    // Each delegates to the matching Swift `appcoreObserveGet*` thunk, which
    // atomically registers a per-property observation scope AND returns the
    // current value. The callback fires onChange at most once per registration.

    fun observeGetStories(callback: ObservationCallback): List<Story> =
        json.decodeFromString<List<Story>>(AppCoreAndroid.appcoreObserveGetStoriesJSON(callback))

    fun observeGetIsLoading(callback: ObservationCallback): Boolean =
        AppCoreAndroid.appcoreObserveGetIsLoading(callback)

    fun observeGetSearchQuery(callback: ObservationCallback): String =
        AppCoreAndroid.appcoreObserveGetSearchQuery(callback)

    fun observeGetLastRefreshedAt(callback: ObservationCallback): String? =
        AppCoreAndroid.appcoreObserveGetLastRefreshedAt(callback).takeIf { it.isNotEmpty() }

    fun observeGetLoadError(callback: ObservationCallback): String? =
        AppCoreAndroid.appcoreObserveGetLoadError(callback).takeIf { it.isNotEmpty() }

    fun dispatch(event: AppEvent) {
        AppCoreAndroid.appcoreDispatch(json.encodeToString(AppEvent.serializer(), event))
    }

    /**
     * Awaitable cousin of [dispatch] — mirrors iOS's
     * `AppEventDispatch.run(_:) async`. The coroutine suspends until the
     * Swift dispatch completes. Pull-to-refresh uses this so the indicator
     * stays visible for the actual fetch lifetime.
     */
    suspend fun dispatchAwait(event: AppEvent) = awaitWithCompletion { completion ->
        AppCoreAndroid.appcoreDispatchAwait(
            json.encodeToString(AppEvent.serializer(), event),
            completion,
        )
    }
}

@androidx.compose.runtime.Composable
fun rememberAppModel(): AppModelHolder = AppModelHolder

/**
 * Adapts a JNI thunk shaped as `(args…, AndroidCompletion)` into a
 * Kotlin `suspend fun`. The coroutine resumes when Swift fires
 * `completion.complete()`.
 */
suspend inline fun awaitWithCompletion(
    crossinline thunk: (AndroidCompletion) -> Unit,
): Unit = suspendCancellableCoroutine { cont ->
    thunk(object : AndroidCompletion {
        override fun complete() {
            if (cont.isActive) cont.resume(Unit) { _, _, _ -> }
        }
    })
}
