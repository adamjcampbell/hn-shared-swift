package com.example.hackernewsreader.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExpandedFullScreenContainedSearchBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
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
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.example.hackernewsreader.R
import hacker.news.reader.Command
import hacker.news.reader.Core
import hacker.news.reader.LoadStatus
import hacker.news.reader.LoadedStories
import hacker.news.reader.Message
import hacker.news.reader.Model
import hacker.news.reader.SendMessageAction
import hacker.news.reader.StoryRow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

private val LocalSendMessage = staticCompositionLocalOf<SendMessageAction> {
    error("LocalSendMessage not provided")
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StoryScreen(core: Core) {
    val context = LocalContext.current
    val scrollBehavior = TopAppBarDefaults.enterAlwaysScrollBehavior()
    val sendMessage = core.sendMessage

    LaunchedEffect(Unit) {
        sendMessage.send(Message.refresh)
    }

    LaunchedEffect(Unit) {
        core.commands.kotlin().collect { command ->
            when (command) {
                is Command.PresentURLCase -> context.launchCustomTab(command.value)
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
        CompositionLocalProvider(LocalSendMessage provides sendMessage) {
            StoriesContent(
                model = core.model,
                modifier = Modifier
                    .padding(innerPadding)
                    .consumeWindowInsets(innerPadding)
                    .fillMaxSize(),
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun StoriesContent(
    model: Model,
    modifier: Modifier = Modifier,
) {
    val searchBarState = rememberSearchBarState()
    val textFieldState = rememberTextFieldState(initialText = model.searchQuery)
    val scope = rememberCoroutineScope()

    // One-way: textFieldState is the source of truth; nothing in the engine writes
    // back to model.searchQuery, so no reverse sync is needed.
    LaunchedEffect(model) {
        snapshotFlow { textFieldState.text.toString() }
            .distinctUntilChanged()
            .collect { model.searchQuery = it }
    }

    val containedSearchBarColors = SearchBarDefaults.containedColors(state = searchBarState)
        .copy(containerColor = MaterialTheme.colorScheme.surface)
    val inputField: @Composable () -> Unit = remember(textFieldState, searchBarState, scope) {
        {
            SearchBarDefaults.InputField(
                textFieldState = textFieldState,
                searchBarState = searchBarState,
                onSearch = { scope.launch { searchBarState.animateToCollapsed() } },
                placeholder = { Text(stringResource(R.string.search_placeholder)) },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                colors = containedSearchBarColors.inputFieldColors,
            )
        }
    }

    Box(modifier = modifier) {
        Column(Modifier.fillMaxSize()) {
            SearchBar(
                state = searchBarState,
                inputField = inputField,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
            FeedList(
                stories = model.feedStories.asList(),
                loaded = model.feedLoaded,
                initialStatus = model.feedInitialStatus,
                loadMoreStatus = model.feedLoadMoreStatus,
                modifier = Modifier.fillMaxWidth().weight(1f),
            )
        }

        ExpandedFullScreenContainedSearchBar(
            state = searchBarState,
            inputField = inputField,
            colors = containedSearchBarColors,
        ) {
            SearchResults(
                query = textFieldState.text.toString(),
                results = model.searchResults.asList(),
                loaded = model.searchLoaded,
                initialStatus = model.searchInitialStatus,
                loadMoreStatus = model.searchLoadMoreStatus,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FeedList(
    stories: List<StoryRow>,
    loaded: LoadedStories?,
    initialStatus: LoadStatus,
    loadMoreStatus: LoadStatus,
    modifier: Modifier = Modifier,
) {
    val sendMessage = LocalSendMessage.current
    PullToRefreshBox(
        isRefreshing = initialStatus.isLoading,
        onRefresh = { sendMessage.send(Message.refresh) },
        modifier = modifier,
    ) {
        LazyColumn(contentPadding = PaddingValues(top = 8.dp, bottom = 16.dp)) {
            item(key = "header") {
                FeedHeaderCard(
                    storyCount = stories.size,
                    unreadCount = stories.count { !it.isRead },
                    lastRefreshedAt = loaded?.loadedAt,
                    loadError = initialStatus.error,
                )
            }
            storyRows(stories)
            if (loaded?.hasMore == true) {
                item(key = "load-more") { LoadMoreRow(status = loadMoreStatus) }
            }
        }
    }
}

@Composable
private fun SearchResults(
    query: String,
    results: List<StoryRow>,
    loaded: LoadedStories?,
    initialStatus: LoadStatus,
    loadMoreStatus: LoadStatus,
) {
    val isLoading = initialStatus.isLoading
    Box(Modifier.fillMaxSize()) {
        LazyColumn {
            item(key = "search-header") {
                SearchHeader(query = query, isLoading = isLoading, error = initialStatus.error)
            }
            storyRows(results)
            if (loaded?.hasMore == true) {
                item(key = "search-load-more") { LoadMoreRow(status = loadMoreStatus) }
            }
        }
        if (!isLoading && results.isEmpty() && query.isNotEmpty()) {
            EmptyResultsOverlay(query = query)
        }
    }
}

private fun LazyListScope.storyRows(stories: List<StoryRow>) {
    items(stories, key = { it.id }) { story ->
        StoryRowView(story = story)
    }
}

@Composable
private fun FeedHeaderCard(
    storyCount: Int,
    unreadCount: Int,
    lastRefreshedAt: skip.foundation.Date?,
    loadError: String?,
) {
    val never = stringResource(R.string.last_refreshed_never)
    val refreshLabel = lastRefreshedAt?.let(::formatTimestamp) ?: never
    val meta = if (storyCount == 0) {
        stringResource(R.string.last_refreshed_label, refreshLabel)
    } else {
        stringResource(R.string.unread_meta_label, unreadCount, storyCount, refreshLabel)
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
                text = stringResource(R.string.front_page_title),
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
private fun SearchHeader(
    query: String,
    isLoading: Boolean,
    error: String?,
) {
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
                    text = stringResource(R.string.searching_for_title, query),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f),
                )
                // Always mounted so the title doesn't shift width as the spinner fades in/out.
                val spinnerAlpha by animateFloatAsState(
                    targetValue = if (isLoading) 1f else 0f,
                    label = "searchHeaderSpinnerAlpha",
                )
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp).alpha(spinnerAlpha),
                    strokeWidth = 2.dp,
                )
            }
            if (error != null) {
                Text(
                    text = error,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

@Composable
private fun StoryRowView(story: StoryRow) {
    val sendMessage = LocalSendMessage.current
    val contentColor = if (story.isRead) {
        MaterialTheme.colorScheme.onSurfaceVariant
    } else {
        MaterialTheme.colorScheme.onSurface
    }
    val rowModifier = if (story.url != null) {
        Modifier.clickable { sendMessage.send(Message.openStory(story.id)) }
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
    val currentToggle by rememberUpdatedState { sendMessage.send(Message.toggleRead(story.id)) }
    val dismissState = rememberSwipeToDismissBoxState()
    LaunchedEffect(dismissState) {
        snapshotFlow { dismissState.currentValue }.collect { value ->
            if (value == SwipeToDismissBoxValue.StartToEnd) {
                currentToggle()
                dismissState.reset()
            }
        }
    }

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
                    text = "by ${story.author} · ${story.score} pts · ${story.commentCount} comments · $host",
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
private fun LoadMoreRow(status: LoadStatus) {
    val sendMessage = LocalSendMessage.current
    val showError = status.error != null && !status.isLoading

    // Compose analogue of SwiftUI's `LoadMoreRow.onAppear` — LazyColumn only composes the row
    // when the user scrolls it into view, so this fires at the same moment .onAppear would.
    LaunchedEffect(Unit) {
        sendMessage.send(Message.loadMore)
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = status.error ?: stringResource(R.string.load_more_loading),
            style = MaterialTheme.typography.bodySmall,
            color = if (showError) MaterialTheme.colorScheme.error
                    else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        Box(contentAlignment = Alignment.Center) {
            CircularProgressIndicator(
                modifier = Modifier
                    .size(24.dp)
                    .alpha(if (showError) 0f else 1f),
                strokeWidth = 2.dp,
            )
            Button(
                onClick = { sendMessage.send(Message.loadMore) },
                enabled = showError,
                modifier = Modifier.alpha(if (showError) 1f else 0f),
            ) {
                Text(stringResource(R.string.load_more_retry))
            }
        }
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

private fun formatTimestamp(date: skip.foundation.Date): String {
    val formatter = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault())
    return formatter.format(java.util.Date((date.timeIntervalSince1970 * 1000.0).toLong()))
}
