package com.example.appcore.state

import com.example.appcore.bridge.AndroidCompletion
import com.example.appcore.bridge.AppCoreAndroid
import com.example.appcore.bridge.CommandSink
import com.example.appcore.bridge.ObservationCallback
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.suspendCancellableCoroutine

data class Story(
    val id: String,
    val title: String,
    val author: String,
    val points: Int,
    val commentCount: Int,
    val url: String? = null,
    val createdAt: Long,
    val isRead: Boolean = false,
)

/**
 * Mirrors the Swift `AppEvent` enum. The Kotlin sealed class is the type
 * UI code emits via `holder.dispatch(...)`; the holder dispatches each
 * case to its matching typed JNI thunk, so no wire format crosses the
 * boundary.
 */
sealed class AppEvent {
    data class ToggleRead(val id: String) : AppEvent()
    data class OpenStory(val id: String) : AppEvent()
    data object Refresh : AppEvent()
}

/**
 * Mirrors the Swift `AppCommand` enum — the Core → UI direction. The
 * holder receives one typed `CommandSink` callback per case (e.g.
 * `presentURL(value:)`) and reconstructs the sealed-class instance for
 * downstream consumers' `when` exhaustiveness.
 */
sealed class AppCommand {
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

    /** Called from Swift via JNI on every `.presentURL` yield from `AppModel.commands`. */
    override fun presentURL(value: String) {
        _commands.trySend(AppCommand.PresentURL(value))
    }

    fun setSearchQuery(value: String) =
        AppCoreAndroid.appcoreSetSearchQuery(value)

    // MARK: - Per-property observable fields
    // Each is a SwiftState backed by the matching fused Swift
    // `appcoreObserveGet*` thunk. Use `by` in a Composable to subscribe:
    //   val stories by holder.stories.asState()

    val stories = SwiftState<List<Story>> { cb ->
        val peer = AppCoreAndroid.appcoreObserveGetStoriesHandle(cb)
        try {
            val n = AppCoreAndroid.appcoreStoriesCount(peer)
            List(n) { i ->
                Story(
                    id           = AppCoreAndroid.appcoreStoryId(peer, i),
                    title        = AppCoreAndroid.appcoreStoryTitle(peer, i),
                    author       = AppCoreAndroid.appcoreStoryAuthor(peer, i),
                    points       = AppCoreAndroid.appcoreStoryPoints(peer, i),
                    commentCount = AppCoreAndroid.appcoreStoryCommentCount(peer, i),
                    url          = AppCoreAndroid.appcoreStoryURL(peer, i).ifEmpty { null },
                    createdAt    = AppCoreAndroid.appcoreStoryCreatedAtMillis(peer, i),
                    isRead       = AppCoreAndroid.appcoreStoryIsRead(peer, i),
                )
            }
        } finally {
            AppCoreAndroid.appcoreStoriesRelease(peer)
        }
    }
    val isLoading = SwiftState(AppCoreAndroid::appcoreObserveGetIsLoading)
    val searchQuery = SwiftState(AppCoreAndroid::appcoreObserveGetSearchQuery)
    val lastRefreshedAt = SwiftState<String?> { cb -> AppCoreAndroid.appcoreObserveGetLastRefreshedAt(cb).takeIf { it.isNotEmpty() } }
    val loadError = SwiftState<String?> { cb -> AppCoreAndroid.appcoreObserveGetLoadError(cb).takeIf { it.isNotEmpty() } }

    fun dispatch(event: AppEvent) = when (event) {
        is AppEvent.ToggleRead -> AppCoreAndroid.appcoreToggleRead(event.id)
        is AppEvent.OpenStory  -> AppCoreAndroid.appcoreOpenStory(event.id)
        AppEvent.Refresh       -> AppCoreAndroid.appcoreRefresh()
    }

    /**
     * Awaitable cousin of [dispatch] — mirrors iOS's
     * `AppEventDispatch.run(.refresh) async`. The coroutine suspends until the
     * Swift dispatch completes. Pull-to-refresh uses this so the indicator
     * stays visible for the actual fetch lifetime.
     *
     * Only [AppEvent.Refresh] has a Swift-side awaitable thunk; toggle/open
     * are fire-and-forget on both platforms, so this falls back to firing
     * the sync thunk and resuming immediately for those cases.
     */
    suspend fun dispatchAwait(event: AppEvent) = awaitWithCompletion { completion ->
        when (event) {
            AppEvent.Refresh       -> AppCoreAndroid.appcoreRefreshAwait(completion)
            is AppEvent.ToggleRead -> { AppCoreAndroid.appcoreToggleRead(event.id); completion.complete() }
            is AppEvent.OpenStory  -> { AppCoreAndroid.appcoreOpenStory(event.id); completion.complete() }
        }
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
