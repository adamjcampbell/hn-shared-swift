package com.example.appcore.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
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
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExpandedFullScreenSearchBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SearchBar
import androidx.compose.material3.SearchBarDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSearchBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.example.appcore.R
import com.example.appcore.state.AppEvent
import com.example.appcore.state.AppState
import com.example.appcore.state.Story
import com.example.appcore.state.rememberAppModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StoryScreen() {
    val holder = rememberAppModel()
    val state = holder.state
    val scope = rememberCoroutineScope()
    val scrollBehavior = TopAppBarDefaults.enterAlwaysScrollBehavior()

    // Initial fetch: front page on first composition.
    LaunchedEffect(Unit) {
        holder.dispatch(AppEvent.Refresh)
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
        StoriesContent(
            state = state,
            onRefresh = { scope.launch { holder.dispatch(AppEvent.Refresh) } },
            onSearchTextChanged = { holder.dispatch(AppEvent.SetSearchQuery(it)) },
            onToggleRead = { holder.dispatch(AppEvent.ToggleRead(it)) },
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
    onRefresh: () -> Unit,
    onSearchTextChanged: (String) -> Unit,
    onToggleRead: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val searchBarState = rememberSearchBarState()
    val textFieldState = rememberTextFieldState()
    val scope = rememberCoroutineScope()

    // Pipe textfield changes into AppCore as `setSearchQuery` events.
    // distinctUntilChanged guards against snapshotFlow re-emitting on
    // cursor / selection changes.
    LaunchedEffect(Unit) {
        snapshotFlow { textFieldState.text.toString() }
            .distinctUntilChanged()
            .collect(onSearchTextChanged)
    }

    // Debounce + dispatch Refresh whenever AppCore's searchQuery changes.
    // Mirrors iOS's `task(id:)` debounce. `drop(1)` skips the initial
    // null/empty emission (the LaunchedEffect(Unit) above already kicks
    // off the first Refresh on launch).
    LaunchedEffect(Unit) {
        snapshotFlow { state?.searchQuery }
            .filterNotNull()
            .distinctUntilChanged()
            .drop(1)
            .collect {
                delay(250)
                onRefresh()
            }
    }

    val stories = state?.stories ?: emptyList()
    val read = state?.read ?: emptySet()
    val isLoading = state?.isLoading ?: false

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
                isRefreshing = isLoading,
                onRefresh = onRefresh,
                modifier = Modifier.fillMaxSize(),
            ) {
                LazyColumn(contentPadding = PaddingValues(top = 8.dp, bottom = 16.dp)) {
                    item(key = "header") {
                        HeaderCard(
                            searchQuery = state?.searchQuery.orEmpty(),
                            storyCount = stories.size,
                            unreadCount = stories.count { !read.contains(it.id) },
                            isLoading = isLoading,
                            lastRefreshedAt = state?.lastRefreshedAt,
                            loadError = state?.loadError,
                        )
                    }
                    storyRows(stories, read, onToggleRead)
                }
            }

            if (!isLoading
                && stories.isEmpty()
                && state?.searchQuery?.isNotEmpty() == true
            ) {
                EmptyResultsOverlay(query = state.searchQuery)
            }
        }
    }

    ExpandedFullScreenSearchBar(state = searchBarState, inputField = inputField) {
        LazyColumn { storyRows(stories, read, onToggleRead) }
    }
}

private fun LazyListScope.storyRows(
    stories: List<Story>,
    read: Set<String>,
    onToggleRead: (String) -> Unit,
) {
    items(stories, key = { it.id }) { story ->
        StoryRow(
            story = story,
            isRead = read.contains(story.id),
            onToggle = { onToggleRead(story.id) },
        )
    }
}

@Composable
private fun HeaderCard(
    searchQuery: String,
    storyCount: Int,
    unreadCount: Int,
    isLoading: Boolean,
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
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f),
                )
                if (isLoading) {
                    CircularProgressIndicator(
                        modifier = Modifier.padding(start = 8.dp),
                        strokeWidth = 2.dp,
                    )
                }
            }
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
private fun StoryRow(story: Story, isRead: Boolean, onToggle: () -> Unit) {
    val uriHandler = LocalUriHandler.current
    val contentColor = if (isRead) {
        MaterialTheme.colorScheme.onSurfaceVariant
    } else {
        MaterialTheme.colorScheme.onSurface
    }
    val rowModifier = story.url?.let { url ->
        Modifier.clickable { uriHandler.openUri(url) }
    } ?: Modifier

    val host = story.url?.let { runCatching { java.net.URI(it).host }.getOrNull() }
        ?: "news.ycombinator.com"

    CompositionLocalProvider(LocalContentColor provides contentColor) {
        ListItem(
            modifier = rowModifier,
            headlineContent = { Text(story.title) },
            supportingContent = {
                Text(
                    text = "by ${story.author} · ${story.points} pts · ${story.commentCount} comments · $host",
                    style = MaterialTheme.typography.bodySmall,
                    textDecoration = if (isRead) TextDecoration.LineThrough else TextDecoration.None,
                )
            },
            trailingContent = {
                IconButton(onClick = onToggle) {
                    Icon(
                        imageVector = if (isRead) Icons.Filled.Circle else Icons.Outlined.Circle,
                        contentDescription = stringResource(
                            if (isRead) R.string.mark_unread_action else R.string.mark_read_action,
                        ),
                        tint = if (isRead) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            colors = ListItemDefaults.colors(
                containerColor = Color.Transparent,
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
