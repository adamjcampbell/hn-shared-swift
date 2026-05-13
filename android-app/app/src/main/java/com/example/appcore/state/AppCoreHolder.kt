package com.example.appcore.state

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import app.core.AppCore

/**
 * Process-wide singleton AppCore. SkipFuse intercepts the standard
 * `@Observable` macro's tracking calls and routes them through Compose's
 * snapshot system, so reading `appCore.state.searchQuery` inside a
 * `@Composable` registers as a tracked read; mutating it from any thread
 * triggers recomposition. No SwiftState wrapper, no per-property
 * boilerplate.
 */
private val sharedAppCore: AppCore by lazy { AppCore() }

@Composable
fun rememberAppCore(): AppCore = remember { sharedAppCore }
