package com.example.appcore

import android.app.Application
import com.example.appcore.state.AppModelHolder

/**
 * Initialises the singleton AppCore bridge once per process.
 *
 * The Swift side holds a single `AppModel` in `AndroidBridge.shared`; the
 * Kotlin side mirrors that with the `AppModelHolder` object. We call
 * `start()` here so the eager initial snapshot is delivered before any
 * Compose tree is created, and we never tear it down — process death is
 * the only lifecycle event that matters.
 */
class AppCoreApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AppModelHolder.start()
    }
}
