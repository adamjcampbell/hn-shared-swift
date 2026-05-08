package com.example.appcore.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExpandedFullScreenSearchBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SearchBar
import androidx.compose.material3.SearchBarDefaults
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSearchBarState
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.example.appcore.R
import com.example.appcore.state.AppCommand
import com.example.appcore.state.AppEvent
import com.example.appcore.state.AppState
import com.example.appcore.state.Story
import com.example.appcore.state.asMutableState
import com.example.appcore.state.asState
import com.example.appcore.state.rememberAppModel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StoryScreen() {
    val holder = rememberAppModel()
    val state = holder.state
    val context = LocalContext.current
    val scrollBehavior = TopAppBarDefaults.enterAlwaysScrollBehavior()

    // Initial fetch: front page on first composition. Awaitable so the
    // LaunchedEffect coroutine ties to the screen's lifecycle — if the
    // user navigates away mid-fetch, the coroutine is cancelled
    // (Kotlin-side; the Swift Task runs to completion, harmlessly).
    LaunchedEffect(Unit) {
        holder.dispatchAwait(AppEvent.Refresh)
    }

    // One-shot commands from the core. Each emission is consumed exactly
    // once by the receiveAsFlow channel — recomposition can't replay it.
    LaunchedEffect(holder) {
        holder.commands.collect { command ->
            when (command) {
                is AppCommand.PresentURL -> context.launchCustomTab(command.value)
            }
        }
    }

    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.app_title)) },
                colors = TopAppBarDefaults.topAppBarColors(
                    scrolledContainerColor = MaterialTheme.colorScheme.surface,
                ),
                scrollBehavior = scrollBehavior,
            )
        },
    ) { innerPadding ->
        // searchQuery flows through the per-property bridge: typing
        // pushes through `holder.searchQuery.set` → AppCoreAndroid; the
        // SearchQuerySink-driven `holder.searchQuery` State pushes back
        // for cold-start + programmatic Swift writes (echoes of typing
        // are filtered on the bridge actor's `lastSetterValue` dedup).
        // Compose's TextFieldState owns the in-progress typing buffer —
        // we sync it to/from `holder.searchQuery` via two snapshotFlow
        // collectors below.
        val authoritativeSearchQuery by holder.searchQuery.asState()
        // isLoading flows through the per-property bridge as well — the
        // model's `runFetch` is the single writer, so this is one-way
        // Swift→Kotlin in practice. `asMutableState` matches the
        // searchQuery shape (and Compose's `var x by state` ergonomics)
        // even though no consumer here actually writes.
        val isRefreshing by holder.isLoading.asMutableState()
        StoriesContent(
            state = state,
            authoritativeSearchQuery = authoritativeSearchQuery,
            isRefreshing = isRefreshing,
            onSearchQueryWrite = holder.searchQuery::set,
            onRefresh = { holder.dispatchAwait(AppEvent.Refresh) },
            onToggleRead = { holder.dispatch(AppEvent.ToggleRead(it)) },
            onOpenStory = { holder.dispatch(AppEvent.OpenStory(it)) },
            modifier = Modifier
                .padding(innerPadding)
                .consumeWindowInsets(innerPadding)
                .fillMaxSize(),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StoriesContent(
    state: AppState?,
    authoritativeSearchQuery: String,
    isRefreshing: Boolean,
    onSearchQueryWrite: (String) -> Unit,
    onRefresh: suspend () -> Unit,
    onToggleRead: (String) -> Unit,
    onOpenStory: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val searchBarState = rememberSearchBarState()
    val textFieldState = rememberTextFieldState(initialText = authoritativeSearchQuery)
    val scope = rememberCoroutineScope()

    // User typing → AppCore. `BridgedSource.set` calls the JNI setter
    // synchronously (Swift bridge has the new value before this
    // returns); listeners are NOT notified locally because the Swift
    // `lastSetterValue` echo dedup suppresses the round-trip and
    // `textFieldState` already owns the typing buffer.
    LaunchedEffect(Unit) {
        snapshotFlow { textFieldState.text.toString() }
            .distinctUntilChanged()
            .collect(onSearchQueryWrite)
    }
    // Authoritative writes from AppCore (cold-start initial,
    // future programmatic clears) → TextFieldState. The
    // `lastSetterValue` dedup on the Swift bridge filters echoes of
    // user-typed writes, so this only fires for genuine
    // out-of-band updates. The dropWhile-guarded race in the
    // event-dispatch architecture doesn't exist here: Compose's
    // initial textFieldState text == bridge's cold-start emission ""
    // by construction, so the conditional below skips it.
    LaunchedEffect(Unit) {
        snapshotFlow { authoritativeSearchQuery }
            .distinctUntilChanged()
            .collect { value ->
                if (textFieldState.text.toString() != value) {
                    textFieldState.edit { replace(0, length, value) }
                }
            }
    }

    val searchQuery = textFieldState.text.toString()
    val stories = state?.stories ?: emptyList()

    // Pull-to-refresh's indicator is driven by `state.isLoading` from
    // AppCore via the per-property bridge — see [AppModelHolder.isLoading].
    // The model's `runFetch` toggles it for every fetch (debounced
    // search + explicit `.refresh`), so the indicator surfaces on
    // search-typing fetches too, not just pull-to-refresh.
    val pullToRefresh: () -> Unit = { scope.launch { onRefresh() } }

    val inputField: @Composable () -> Unit = remember(textFieldState, searchBarState, scope) {
        {
            SearchBarDefaults.InputField(
                textFieldState = textFieldState,
                searchBarState = searchBarState,
                onSearch = { scope.launch { searchBarState.animateToCollapsed() } },
                placeholder = { Text(stringResource(R.string.search_placeholder)) },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            )
        }
    }

    Column(modifier = modifier) {
        SearchBar(
            state = searchBarState,
            inputField = inputField,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
        ) {
            PullToRefreshBox(
                isRefreshing = isRefreshing,
                onRefresh = pullToRefresh,
                modifier = Modifier.fillMaxSize(),
            ) {
                LazyColumn(contentPadding = PaddingValues(top = 8.dp, bottom = 16.dp)) {
                    item(key = "header") {
                        HeaderCard(
                            searchQuery = searchQuery,
                            storyCount = stories.size,
                            unreadCount = stories.count { !it.isRead },
                            lastRefreshedAt = state?.lastRefreshedAt,
                            loadError = state?.loadError,
                        )
                    }
                    storyRows(stories, onToggleRead, onOpenStory)
                }
            }

            if (!isRefreshing && stories.isEmpty() && searchQuery.isNotEmpty()) {
                EmptyResultsOverlay(query = searchQuery)
            }
        }
    }

    ExpandedFullScreenSearchBar(state = searchBarState, inputField = inputField) {
        LazyColumn { storyRows(stories, onToggleRead, onOpenStory) }
    }
}

private fun LazyListScope.storyRows(
    stories: List<Story>,
    onToggleRead: (String) -> Unit,
    onOpenStory: (String) -> Unit,
) {
    items(stories, key = { it.id }) { story ->
        StoryRow(
            story = story,
            onToggle = { onToggleRead(story.id) },
            onOpen = { onOpenStory(story.id) },
        )
    }
}

@Composable
private fun HeaderCard(
    searchQuery: String,
    storyCount: Int,
    unreadCount: Int,
    lastRefreshedAt: String?,
    loadError: String?,
) {
    val never = stringResource(R.string.last_refreshed_never)
    val title = if (searchQuery.isEmpty()) {
        stringResource(R.string.front_page_title)
    } else {
        stringResource(R.string.search_title, searchQuery)
    }
    val meta = if (storyCount == 0) {
        stringResource(R.string.last_refreshed_label, lastRefreshedAt?.let(::formatTimestamp) ?: never)
    } else {
        stringResource(
            R.string.unread_meta_label,
            unreadCount,
            storyCount,
            lastRefreshedAt?.let(::formatTimestamp) ?: never,
        )
    }

    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
        ),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 16.dp),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
            )
            Text(
                text = meta,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (loadError != null) {
                Text(
                    text = loadError,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

@Composable
private fun StoryRow(
    story: Story,
    onToggle: () -> Unit,
    onOpen: () -> Unit,
) {
    val contentColor = if (story.isRead) {
        MaterialTheme.colorScheme.onSurfaceVariant
    } else {
        MaterialTheme.colorScheme.onSurface
    }
    val rowModifier = if (story.url != null) {
        Modifier.clickable { onOpen() }
    } else {
        Modifier
    }

    val host = remember(story.url) {
        story.url?.let { runCatching { java.net.URI(it).host }.getOrNull() }
            ?: "news.ycombinator.com"
    }

    val swipeLabel = stringResource(
        if (story.isRead) R.string.mark_unread_action else R.string.mark_read_action,
    )
    // rememberSwipeToDismissBoxState captures confirmValueChange at first
    // construction; rememberUpdatedState lets the captured lambda reach the
    // latest onToggle without re-keying (and resetting) the swipe state.
    val currentOnToggle by rememberUpdatedState(onToggle)
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value == SwipeToDismissBoxValue.StartToEnd) {
                currentOnToggle()
            }
            false
        },
    )

    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromEndToStart = false,
        backgroundContent = {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.primaryContainer)
                    .padding(horizontal = 24.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                Icon(
                    imageVector = if (story.isRead) Icons.Outlined.Circle else Icons.Filled.CheckCircle,
                    contentDescription = swipeLabel,
                    tint = MaterialTheme.colorScheme.onPrimaryContainer,
                )
            }
        },
    ) {
        ListItem(
            modifier = rowModifier,
            headlineContent = { Text(story.title) },
            supportingContent = {
                Text(
                    text = "by ${story.author} · ${story.points} pts · ${story.commentCount} comments · $host",
                    style = MaterialTheme.typography.bodySmall,
                )
            },
            colors = ListItemDefaults.colors(
                containerColor = MaterialTheme.colorScheme.surface,
                headlineColor = contentColor,
                supportingColor = contentColor,
            ),
        )
    }
}

@Composable
private fun EmptyResultsOverlay(query: String) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = stringResource(R.string.no_results, query),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// Best-effort; production code would use kotlinx-datetime.
private fun formatTimestamp(iso8601: String): String =
    iso8601.substringAfter("T").substringBeforeLast(".").take(8)
