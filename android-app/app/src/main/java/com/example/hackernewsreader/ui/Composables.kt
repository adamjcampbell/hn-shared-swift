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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.OpenInNew
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
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SearchBar
import androidx.compose.material3.SearchBarDefaults
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSearchBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.ui.NavDisplay
import hacker.news.reader.CommentRow
import hacker.news.reader.Command
import hacker.news.reader.Core
import hacker.news.reader.LoadStatus
import hacker.news.reader.LoadedStories
import hacker.news.reader.Message
import hacker.news.reader.Model
import hacker.news.reader.SendMessageAction
import hacker.news.reader.StoryRow
import hacker.news.reader.Strings
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

private val LocalSendMessage = staticCompositionLocalOf<SendMessageAction> {
    error("LocalSendMessage not provided")
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StoryScreen(core: Core) {
    val context = LocalContext.current
    val sendMessage = core.sendMessage
    val backStack = rememberNavBackStack(StoriesRoute)

    LaunchedEffect(Unit) { sendMessage.send(Message.refresh) }

    LaunchedEffect(Unit) {
        core.commands.kotlin().collect { command ->
            when (command) {
                is Command.PresentURLCase -> context.launchCustomTab(command.value)
            }
        }
    }

    CompositionLocalProvider(LocalSendMessage provides sendMessage) {
        NavDisplay(
            backStack = backStack,
            onBack = { backStack.removeLastOrNull() },
            entryProvider = entryProvider {
                entry<StoriesRoute> {
                    StoriesScreen(
                        model = core.model,
                        onStoryClick = { storyID -> backStack.add(CommentsRoute(storyID)) },
                    )
                }
                entry<CommentsRoute> { route ->
                    CommentsScreen(
                        model = core.model,
                        storyId = route.storyId,
                        onBack = { backStack.removeLastOrNull() },
                    )
                }
            },
        )
    }
}

@Serializable
private data object StoriesRoute : NavKey

@Serializable
private data class CommentsRoute(val storyId: String) : NavKey

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StoriesScreen(
    model: Model,
    onStoryClick: (String) -> Unit,
) {
    val scrollBehavior = TopAppBarDefaults.enterAlwaysScrollBehavior()

    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            TopAppBar(
                title = { Text(Strings.appTitle) },
                colors = TopAppBarDefaults.topAppBarColors(
                    scrolledContainerColor = MaterialTheme.colorScheme.surface,
                ),
                scrollBehavior = scrollBehavior,
            )
        },
    ) { innerPadding ->
        StoriesContent(
            model = model,
            onStoryClick = onStoryClick,
            modifier = Modifier
                .padding(innerPadding)
                .consumeWindowInsets(innerPadding)
                .fillMaxSize(),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CommentsScreen(
    model: Model,
    storyId: String,
    onBack: () -> Unit,
) {
    val sendMessage = LocalSendMessage.current
    val story = model.storyRow(id = storyId)

    LaunchedEffect(storyId) {
        sendMessage.send(Message.viewStory(storyId))
        sendMessage.send(Message.loadComments(storyId))
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(Strings.commentsTitle) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null)
                    }
                },
                actions = {
                    if (story?.url != null) {
                        IconButton(onClick = { sendMessage.send(Message.openStoryURL(storyId)) }) {
                            Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = Strings.openArticle)
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    scrolledContainerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        },
    ) { innerPadding ->
        if (story == null) {
            EmptyMessage(
                text = Strings.commentsMissingStory,
                modifier = Modifier
                    .padding(innerPadding)
                    .consumeWindowInsets(innerPadding)
                    .fillMaxSize(),
            )
        } else {
            CommentsContent(
                model = model,
                storyId = storyId,
                story = story,
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
    onStoryClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val searchBarState = rememberSearchBarState()
    val textFieldState = rememberBoundTextFieldState(model::searchQuery)
    val scope = rememberCoroutineScope()

    val containedSearchBarColors = SearchBarDefaults.containedColors(state = searchBarState)
        .copy(containerColor = MaterialTheme.colorScheme.surface)
    val inputField: @Composable () -> Unit = remember(textFieldState, searchBarState, scope) {
        {
            SearchBarDefaults.InputField(
                textFieldState = textFieldState,
                searchBarState = searchBarState,
                onSearch = { scope.launch { searchBarState.animateToCollapsed() } },
                placeholder = { Text(Strings.searchPlaceholder) },
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
                subtitle = model.feedHeaderSubtitle,
                onStoryClick = onStoryClick,
                modifier = Modifier.fillMaxWidth().weight(1f),
            )
        }

        ExpandedFullScreenContainedSearchBar(
            state = searchBarState,
            inputField = inputField,
            colors = containedSearchBarColors,
        ) {
            SearchResults(
                query = model.searchQuery,
                results = model.searchResults.asList(),
                loaded = model.searchLoaded,
                initialStatus = model.searchInitialStatus,
                loadMoreStatus = model.searchLoadMoreStatus,
                onStoryClick = onStoryClick,
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
    subtitle: String,
    onStoryClick: (String) -> Unit,
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
                    subtitle = subtitle,
                    loadError = initialStatus.error,
                )
            }
            storyRows(stories, onStoryClick)
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
    onStoryClick: (String) -> Unit,
) {
    val isLoading = initialStatus.isLoading
    Box(Modifier.fillMaxSize()) {
        LazyColumn {
            item(key = "search-header") {
                SearchHeader(query = query, isLoading = isLoading, error = initialStatus.error)
            }
            storyRows(results, onStoryClick)
            if (loaded?.hasMore == true) {
                item(key = "search-load-more") { LoadMoreRow(status = loadMoreStatus) }
            }
        }
        if (!isLoading && results.isEmpty() && query.isNotEmpty()) {
            EmptyResultsOverlay(query = query)
        }
    }
}

private fun LazyListScope.storyRows(stories: List<StoryRow>, onStoryClick: (String) -> Unit) {
    items(stories, key = { it.id }) { story ->
        StoryRowView(story = story, onClick = { onStoryClick(story.id) })
    }
}

@Composable
private fun FeedHeaderCard(
    subtitle: String,
    loadError: String?,
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
            Text(
                text = Strings.feedTitle,
                style = MaterialTheme.typography.titleMedium,
            )
            Text(
                text = subtitle,
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
                    text = Strings.searchHeader(query),
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
private fun StoryRowView(story: StoryRow, onClick: () -> Unit) {
    val sendMessage = LocalSendMessage.current
    val contentColor = if (story.isRead) {
        MaterialTheme.colorScheme.onSurfaceVariant
    } else {
        MaterialTheme.colorScheme.onSurface
    }

    val dismissState = rememberSwipeActionState { sendMessage.send(Message.toggleRead(story.id)) }

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
                    contentDescription = story.readActionLabel,
                    tint = MaterialTheme.colorScheme.onPrimaryContainer,
                )
            }
        },
    ) {
        ListItem(
            modifier = Modifier.clickable(onClick = onClick),
            headlineContent = { Text(story.title) },
            supportingContent = {
                Text(
                    text = story.metaLine,
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
private fun CommentsContent(
    model: Model,
    storyId: String,
    story: StoryRow,
    modifier: Modifier = Modifier,
) {
    val rows = model.commentRows(storyID = storyId).asList()
    val status = model.commentsStatus(storyID = storyId)

    LazyColumn(
        modifier = modifier,
        contentPadding = PaddingValues(top = 8.dp, bottom = 16.dp),
    ) {
        item(key = "story") { CommentsStoryHeader(story = story) }
        when {
            rows.isNotEmpty() -> items(rows, key = { it.id }) { row -> CommentRowView(row = row) }
            status.error != null -> item(key = "error") { LoadCommentsErrorRow(status = status, storyId = storyId) }
            status.isLoading || story.commentCount > 0 -> item(key = "loading") { LoadingRow() }
            else -> item(key = "empty") { EmptyMessage(text = Strings.commentsNoComments) }
        }
    }
}

@Composable
private fun CommentsStoryHeader(story: StoryRow) {
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
                text = story.title,
                style = MaterialTheme.typography.titleMedium,
                color = if (story.isRead) MaterialTheme.colorScheme.onSurfaceVariant
                        else MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = story.metaLine,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun CommentRowView(row: CommentRow) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(
                start = 16.dp + (minOf(row.depth, 8) * 12).dp,
                top = 12.dp,
                end = 16.dp,
                bottom = 12.dp,
            ),
    ) {
        Text(
            text = row.metaLine,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = row.text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun LoadingRow() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator()
    }
}

@Composable
private fun LoadCommentsErrorRow(status: LoadStatus, storyId: String) {
    val sendMessage = LocalSendMessage.current

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = status.error ?: "",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier.weight(1f),
        )
        Button(onClick = { sendMessage.send(Message.loadComments(storyId)) }) {
            Text(Strings.tryAgain)
        }
    }
}

@Composable
private fun EmptyMessage(text: String, modifier: Modifier = Modifier.fillMaxWidth()) {
    Box(
        modifier = modifier
            .background(MaterialTheme.colorScheme.background)
            .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun LoadMoreRow(status: LoadStatus) {
    val sendMessage = LocalSendMessage.current
    val showError = status.error != null && !status.isLoading

    LaunchedEffect(Unit) { sendMessage.send(Message.loadMore) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = status.error ?: Strings.loadingMore,
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
                Text(Strings.tryAgain)
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
            text = Strings.searchNoResults(query),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
