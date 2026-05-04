package com.example.appcore.ui

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
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExpandedFullScreenSearchBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.example.appcore.R
import com.example.appcore.state.AppState
import com.example.appcore.state.City
import com.example.appcore.state.rememberAppModel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CityScreen() {
    val holder = rememberAppModel()
    val state = holder.state
    val scope = rememberCoroutineScope()
    val scrollBehavior = TopAppBarDefaults.enterAlwaysScrollBehavior()

    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.cities_title)) },
                // Suppress the default surfaceContainer tonal change on scroll —
                // the SearchBar below the bar already provides the separation.
                colors = TopAppBarDefaults.topAppBarColors(
                    scrolledContainerColor = MaterialTheme.colorScheme.surface,
                ),
                scrollBehavior = scrollBehavior,
            )
        },
    ) { innerPadding ->
        CitiesContent(
            state = state,
            isRefreshing = holder.isRefreshing,
            onRefresh = { scope.launch { holder.refresh() } },
            onSearch = holder::setSearchQuery,
            onToggleFavorite = holder::toggleFavorite,
            modifier = Modifier
                .padding(innerPadding)
                .consumeWindowInsets(innerPadding)
                .fillMaxSize(),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CitiesContent(
    state: AppState?,
    isRefreshing: Boolean,
    onRefresh: () -> Unit,
    onSearch: (String) -> Unit,
    onToggleFavorite: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val searchBarState = rememberSearchBarState()
    val textFieldState = rememberTextFieldState()
    val scope = rememberCoroutineScope()

    // distinctUntilChanged guards against snapshotFlow re-emitting on cursor /
    // selection changes; the initial emission also covers process-death replay
    // when the OS restores textFieldState but AppCore's filter came back empty.
    LaunchedEffect(Unit) {
        snapshotFlow { textFieldState.text.toString() }
            .distinctUntilChanged()
            .collect(onSearch)
    }

    val cities = state?.cities ?: emptyList()
    val favorites = state?.favorites ?: emptySet()

    val inputField: @Composable () -> Unit = remember(textFieldState, searchBarState, scope) {
        {
            SearchBarDefaults.InputField(
                textFieldState = textFieldState,
                searchBarState = searchBarState,
                onSearch = { scope.launch { searchBarState.animateToCollapsed() } },
                placeholder = { Text(stringResource(R.string.filter_cities_label)) },
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
        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = onRefresh,
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
        ) {
            LazyColumn(contentPadding = PaddingValues(top = 8.dp, bottom = 16.dp)) {
                item(key = "header") {
                    HeaderCard(
                        count = state?.globalFavoriteCount,
                        lastRefreshedAt = state?.lastRefreshedAt,
                    )
                }
                cityRows(cities, favorites, onToggleFavorite)
            }
        }
    }

    ExpandedFullScreenSearchBar(state = searchBarState, inputField = inputField) {
        LazyColumn { cityRows(cities, favorites, onToggleFavorite) }
    }
}

private fun LazyListScope.cityRows(
    cities: List<City>,
    favorites: Set<String>,
    onToggleFavorite: (String) -> Unit,
) {
    items(cities, key = { it.id }) { city ->
        CityRow(
            city = city,
            isFavorite = favorites.contains(city.id),
            onToggle = { onToggleFavorite(city.id) },
        )
    }
}

@Composable
private fun HeaderCard(count: Int?, lastRefreshedAt: String?) {
    val unavailable = stringResource(R.string.value_unavailable)
    val never = stringResource(R.string.last_refreshed_never)
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
                text = stringResource(
                    R.string.worldwide_favorites_label,
                    count?.let { "%,d".format(it) } ?: unavailable,
                ),
                style = MaterialTheme.typography.titleMedium,
            )
            Text(
                text = stringResource(
                    R.string.last_refreshed_label,
                    lastRefreshedAt?.let(::formatTimestamp) ?: never,
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun CityRow(city: City, isFavorite: Boolean, onToggle: () -> Unit) {
    ListItem(
        headlineContent = { Text(city.name) },
        supportingContent = { Text(city.country) },
        trailingContent = {
            IconButton(onClick = onToggle) {
                Icon(
                    imageVector = if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                    contentDescription = stringResource(
                        if (isFavorite) R.string.unfavorite_action else R.string.favorite_action,
                    ),
                    tint = if (isFavorite) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    )
}

// Best-effort; production code would use kotlinx-datetime.
private fun formatTimestamp(iso8601: String): String =
    iso8601.substringAfter("T").substringBeforeLast(".").take(8)
