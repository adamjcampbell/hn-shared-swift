package com.example.appcore

import android.app.Application
import com.example.appcore.state.AppStateHolder

/**
 * Initialises the singleton AppCore bridge once per process.
 *
 * The Swift side holds a single `AppState` in `AndroidBridge.shared`; the
 * Kotlin side mirrors that with the `AppStateHolder` object. We call
 * `start()` here so the eager initial snapshot is delivered before any
 * Compose tree is created, and we never tear it down — process death is
 * the only lifecycle event that matters.
 */
class AppCoreApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AppStateHolder.start()
    }
}
