package com.example.appcore.state

import com.example.appcore.bridge.AndroidCompletion
import com.example.appcore.bridge.AppCoreAndroid
import com.example.appcore.bridge.BoolOnChange
import com.example.appcore.bridge.CommandSink
import com.example.appcore.bridge.LongOnChange
import com.example.appcore.bridge.OptionalStringOnChange
import com.example.appcore.bridge.StringOnChange
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.jvm.optionals.getOrNull
import org.swift.swiftkit.core.tuple.Tuple2

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
 * Implements [CommandSink] only. Each Kotlin composable subscribes to a
 * Swift property via `holder.x.asState()` (the [SwiftState.asState]
 * extension), which constructs a [SwiftBinding] that registers an
 * `appcoreObserve*` Task and writes each emission's value into a
 * Compose `MutableState`. Swift fires only the typed `*OnChange`
 * callback for the property that changed, so recomposition is
 * per-composable and per-property.
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
    // Each is a SwiftState wrapping a Swift `appcoreObserve*` thunk plus
    // its typed `*OnChange` callback. The handler lambda passed in by
    // SwiftBinding receives the new value on every emission and writes
    // it to the Compose MutableState directly. Use `by` in a Composable
    // to subscribe:
    //   val stories by holder.stories.asState()

    val stories = SwiftState<List<Story>>(observe = { handler ->
        val (token, initialPeer) = AppCoreAndroid.appcoreObserveStories(LongOnChange { peer ->
            handler(walkStoriesPeer(peer))
        })
        Tuple2(token, walkStoriesPeer(initialPeer))
    })
    val isLoading = SwiftState<Boolean>(observe = { handler ->
        AppCoreAndroid.appcoreObserveIsLoading(BoolOnChange { handler(it) })
    })
    val searchQuery = SwiftState<String>(observe = { handler ->
        AppCoreAndroid.appcoreObserveSearchQuery(StringOnChange { handler(it) })
    })
    val lastRefreshedAt = SwiftState<String?>(observe = { handler ->
        val (token, initial) = AppCoreAndroid.appcoreObserveLastRefreshedAt(
            OptionalStringOnChange { handler(it.getOrNull()) }
        )
        Tuple2(token, initial.getOrNull())
    })
    val loadError = SwiftState<String?>(observe = { handler ->
        val (token, initial) = AppCoreAndroid.appcoreObserveLoadError(
            OptionalStringOnChange { handler(it.getOrNull()) }
        )
        Tuple2(token, initial.getOrNull())
    })

    /**
     * Walks a `StoriesSnapshotPeer` peer pointer into a `List<Story>`,
     * releasing the peer in the `finally` so Swift reclaims it whether
     * the walk succeeded or threw.
     */
    private fun walkStoriesPeer(peer: Long): List<Story> {
        return try {
            val n = AppCoreAndroid.appcoreStoriesCount(peer)
            List(n) { i ->
                Story(
                    id           = AppCoreAndroid.appcoreStoryId(peer, i),
                    title        = AppCoreAndroid.appcoreStoryTitle(peer, i),
                    author       = AppCoreAndroid.appcoreStoryAuthor(peer, i),
                    points       = AppCoreAndroid.appcoreStoryPoints(peer, i),
                    commentCount = AppCoreAndroid.appcoreStoryCommentCount(peer, i),
                    url          = AppCoreAndroid.appcoreStoryURL(peer, i).getOrNull(),
                    createdAt    = AppCoreAndroid.appcoreStoryCreatedAtMillis(peer, i),
                    isRead       = AppCoreAndroid.appcoreStoryIsRead(peer, i),
                )
            }
        } finally {
            AppCoreAndroid.appcoreStoriesRelease(peer)
        }
    }

    fun dispatch(event: AppEvent) = when (event) {
        is AppEvent.ToggleRead -> AppCoreAndroid.appcoreToggleRead(event.id)
        is AppEvent.OpenStory  -> AppCoreAndroid.appcoreOpenStory(event.id)
        AppEvent.Refresh       -> AppCoreAndroid.appcoreRefresh()
    }

    /**
     * Awaitable cousin of [dispatch] — mirrors iOS's
     * `AppEventDispatch.run(.refresh) async`. The coroutine suspends until
     * the Swift dispatch completes. Pull-to-refresh uses this so the
     * indicator stays visible for the actual fetch lifetime.
     *
     * **Cooperative cancellation.** [AppEvent.Refresh] returns a Swift-side
     * Task token; if the awaiting coroutine is cancelled (e.g. its host
     * scope was torn down) we hand the token back via
     * `appcoreCancelTask` to cancel the in-flight dispatch. Toggle/open
     * are fire-and-forget on both platforms, so they fire the sync
     * thunk and resume immediately — no token to track.
     */
    suspend fun dispatchAwait(event: AppEvent): Unit = suspendCancellableCoroutine { cont ->
        val completion = AndroidCompletion {
            if (cont.isActive) cont.resume(Unit) { _, _, _ -> }
        }
        when (event) {
            AppEvent.Refresh -> {
                val token = AppCoreAndroid.appcoreRefreshAwait(completion)
                cont.invokeOnCancellation { AppCoreAndroid.appcoreCancelTask(token) }
            }
            is AppEvent.ToggleRead -> {
                AppCoreAndroid.appcoreToggleRead(event.id)
                completion.complete()
            }
            is AppEvent.OpenStory -> {
                AppCoreAndroid.appcoreOpenStory(event.id)
                completion.complete()
            }
        }
    }
}

@androidx.compose.runtime.Composable
fun rememberAppModel(): AppModelHolder = AppModelHolder
