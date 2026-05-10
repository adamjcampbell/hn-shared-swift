package com.example.appcore.state

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import app.core.AppModel

/**
 * Process-wide singleton AppModel. SkipFuse intercepts the standard
 * `@Observable` macro's tracking calls and routes them through Compose's
 * snapshot system, so reading `appModel.state.searchQuery` inside a
 * `@Composable` registers as a tracked read; mutating it from any thread
 * triggers recomposition. No SwiftState wrapper, no per-property
 * boilerplate.
 */
private val sharedAppModel: AppModel by lazy { AppModel() }

@Composable
fun rememberAppModel(): AppModel = remember { sharedAppModel }
