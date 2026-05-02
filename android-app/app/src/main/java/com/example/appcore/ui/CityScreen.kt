package com.example.appcore.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.example.appcore.state.rememberAppModel
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CityScreen() {
    val holder = rememberAppModel()
    val state = holder.state
    val scope = rememberCoroutineScope()

    var query by remember { mutableStateOf("") }

    PullToRefreshBox(
        isRefreshing = holder.isRefreshing,
        onRefresh = { scope.launch { holder.refresh() } }
    ) {
        Column(Modifier.fillMaxSize()) {
            HeaderCard(
                count = state?.globalFavoriteCount,
                lastRefreshedAt = state?.lastRefreshedAt
            )
            OutlinedTextField(
                value = query,
                onValueChange = {
                    query = it
                    holder.setSearchQuery(it)
                },
                label = { Text("Filter cities") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
            )
            LazyColumn(Modifier.fillMaxSize()) {
                items(state?.cities ?: emptyList()) { city ->
                    CityRow(
                        city = city,
                        isFavorite = state?.favorites?.contains(city.id) == true,
                        onToggle = { holder.toggleFavorite(city.id) }
                    )
                }
            }
        }
    }
}

@Composable
private fun HeaderCard(count: Int?, lastRefreshedAt: String?) {
    Card(Modifier.fillMaxWidth().padding(16.dp)) {
        Column(Modifier.padding(16.dp)) {
            Text(
                text = "Worldwide favorites: ${count?.let { "%,d".format(it) } ?: "—"}",
                style = MaterialTheme.typography.titleMedium
            )
            Text(
                text = "Last refreshed: ${formatTimestamp(lastRefreshedAt)}",
                style = MaterialTheme.typography.bodySmall
            )
        }
    }
}

@Composable
private fun CityRow(city: com.example.appcore.state.City, isFavorite: Boolean, onToggle: () -> Unit) {
    ListItem(
        headlineContent = { Text(city.name) },
        supportingContent = { Text(city.country) },
        trailingContent = {
            IconButton(onClick = onToggle) {
                Icon(
                    imageVector = if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                    contentDescription = if (isFavorite) "Unfavorite" else "Favorite"
                )
            }
        }
    )
}

private fun formatTimestamp(iso8601: String?): String {
    if (iso8601 == null) return "never"
    // Best-effort; production code would use kotlinx-datetime.
    return iso8601.substringAfter("T").substringBeforeLast(".").take(8)
}
