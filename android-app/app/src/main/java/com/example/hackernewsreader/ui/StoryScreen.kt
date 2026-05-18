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
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Button
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Circle
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import hacker.news.reader.AppCommand
import hacker.news.reader.AppCoreHandle
import hacker.news.reader.AppEvent
import hacker.news.reader.AppState
import hacker.news.reader.LoadStatus
import hacker.news.reader.SendAppEvent
import hacker.news.reader.StoryRow
import com.example.hackernewsreader.R
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StoryScreen(core: AppCoreHandle) {
    val context = LocalContext.current
    val scrollBehavior = TopAppBarDefaults.enterAlwaysScrollBehavior()
    val sendEvent = core.sendEvent

    // Initial fetch on first composition.
    LaunchedEffect(Unit) {
        sendEvent.send(AppEvent.refresh)
    }

    // One-shot commands from the core.
    LaunchedEffect(Unit) {
        core.commands.kotlin().collect { command ->
            when (command) {
                is AppCommand.PresentURLCase -> context.launchCustomTab(command.value)
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
        StoriesContent(
            state = core.state,
            sendEvent = sendEvent,
            modifier = Modifier
                .padding(innerPadding)
                .consumeWindowInsets(innerPadding)
                .fillMaxSize(),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun StoriesContent(
    state: AppState,
    sendEvent: SendAppEvent,
    modifier: Modifier = Modifier,
) {
    // SkipFuse routes @Observable property reads through Compose's snapshot
    // system; reading these properties inside a @Composable registers them
    // for tracking and mutations from any thread trigger recomposition.
    val authoritativeSearchQuery = state.searchQuery
    @Suppress("UNCHECKED_CAST")
    val feedStories = state.feedStories.kotlin() as List<StoryRow>
    @Suppress("UNCHECKED_CAST")
    val searchResults = state.searchResults.kotlin() as List<StoryRow>
    val isFeedRefreshing = state.feedInitialStatus.isLoading
    val isSearchLoading = state.searchInitialStatus.isLoading
    val lastRefreshedAt = state.feedLoaded?.loadedAt
    val feedLoadError = state.feedInitialStatus.error
    val searchLoadError = state.searchInitialStatus.error
    val feedHasMore = state.feedLoaded?.hasMore == true
    val searchHasMore = state.searchLoaded?.hasMore == true
    val feedLoadMoreStatus = state.feedLoadMoreStatus
    val searchLoadMoreStatus = state.searchLoadMoreStatus

    val searchBarState = rememberSearchBarState()
    val textFieldState = rememberTextFieldState(initialText = authoritativeSearchQuery)
    val scope = rememberCoroutineScope()

    // User typing → core. Direct property setter; Swift's @Observable
    // setter routes through SkipFuse's Compose snapshot integration, so any
    // composable that read `searchQuery` is invalidated and the next
    // StoriesContent recomposition picks up the new value.
    LaunchedEffect(state) {
        snapshotFlow { textFieldState.text.toString() }
            .distinctUntilChanged()
            .collect { state.searchQuery = it }
    }
    // Authoritative writes from core (cold-start initial, programmatic
    // clears) → TextFieldState.
    LaunchedEffect(authoritativeSearchQuery) {
        if (textFieldState.text.toString() != authoritativeSearchQuery) {
            textFieldState.edit { replace(0, length, authoritativeSearchQuery) }
        }
    }

    val searchQuery = textFieldState.text.toString()

    val feedListState = rememberLazyListState()
    val searchListState = rememberLazyListState()

    val pullToRefresh: () -> Unit = { scope.launch { sendEvent.run(AppEvent.refresh) } }
    val triggerLoadMore: () -> Unit = { scope.launch { sendEvent.run(AppEvent.loadMore) } }

    val shouldLoadMoreFeed by remember(feedListState) {
        derivedStateOf { feedListState.isNearEnd(threshold = 3) }
    }
    LaunchedEffect(shouldLoadMoreFeed, feedHasMore) {
        if (shouldLoadMoreFeed && feedHasMore) {
            sendEvent.run(AppEvent.loadMore)
        }
    }

    val shouldLoadMoreSearch by remember(searchListState) {
        derivedStateOf { searchListState.isNearEnd(threshold = 3) }
    }
    LaunchedEffect(shouldLoadMoreSearch, searchHasMore) {
        if (shouldLoadMoreSearch && searchHasMore) {
            sendEvent.run(AppEvent.loadMore)
        }
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
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
            ) {
                PullToRefreshBox(
                    isRefreshing = isFeedRefreshing,
                    onRefresh = pullToRefresh,
                    modifier = Modifier.fillMaxSize(),
                ) {
                    LazyColumn(
                        state = feedListState,
                        contentPadding = PaddingValues(top = 8.dp, bottom = 16.dp),
                    ) {
                        item(key = "header") {
                            FeedHeaderCard(
                                storyCount = feedStories.size,
                                unreadCount = feedStories.count { !it.isRead },
                                lastRefreshedAt = lastRefreshedAt,
                                loadError = feedLoadError,
                            )
                        }
                        storyRows(feedStories, sendEvent)
                        if (feedHasMore) {
                            item(key = "load-more") {
                                LoadMoreRow(
                                    status = feedLoadMoreStatus,
                                    onRetry = triggerLoadMore,
                                )
                            }
                        }
                    }
                }
            }
        }

        ExpandedFullScreenContainedSearchBar(
            state = searchBarState,
            inputField = inputField,
            colors = containedSearchBarColors,
        ) {
            Box(Modifier.fillMaxSize()) {
                LazyColumn(state = searchListState) {
                    item(key = "search-header") {
                        SearchHeader(
                            query = searchQuery,
                            isLoading = isSearchLoading,
                            error = searchLoadError,
                        )
                    }
                    storyRows(searchResults, sendEvent)
                    if (searchHasMore) {
                        item(key = "search-load-more") {
                            LoadMoreRow(
                                status = searchLoadMoreStatus,
                                onRetry = triggerLoadMore,
                            )
                        }
                    }
                }
                if (!isSearchLoading && searchResults.isEmpty() && searchQuery.isNotEmpty()) {
                    EmptyResultsOverlay(query = searchQuery)
                }
            }
        }
    }
}

private fun LazyListScope.storyRows(
    stories: List<StoryRow>,
    sendEvent: SendAppEvent,
) {
    items(stories, key = { it.id }) { story ->
        StoryRowView(
            story = story,
            onToggle = { sendEvent.send(AppEvent.toggleRead(story.id)) },
            onOpen = { sendEvent.send(AppEvent.openStory(story.id)) },
        )
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
                // Always present in the layout so the title doesn't
                // shift width as the spinner appears/disappears on each
                // debounce cycle. Alpha animates the fade in/out.
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
private fun StoryRowView(
    story: StoryRow,
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
private fun LoadMoreRow(
    status: LoadStatus,
    onRetry: () -> Unit,
) {
    val showError = status.error != null && !status.isLoading
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
                onClick = onRetry,
                enabled = showError,
                modifier = Modifier.alpha(if (showError) 1f else 0f),
            ) {
                Text(stringResource(R.string.load_more_retry))
            }
        }
    }
}

/// True when the last visible row is within `threshold` of the list's
/// tail. Returns `false` while the list is empty so we don't fire on
/// the cold-launch frame before the initial fetch lands.
private fun LazyListState.isNearEnd(threshold: Int): Boolean {
    val info = layoutInfo
    val total = info.totalItemsCount
    if (total == 0) return false
    val last = info.visibleItemsInfo.lastOrNull()?.index ?: return false
    return last >= total - threshold
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
