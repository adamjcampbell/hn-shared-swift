package com.example.appcore

import android.app.Application
import com.example.appcore.state.AppModelHolder

/**
 * Initialises the singleton AppCore bridge once per process.
 *
 * The Swift side holds a single `AppModel` in the `@JavaUIActor`-isolated
 * `Bridge` namespace; the Kotlin side mirrors that with the
 * `AppModelHolder` object. We call `start()` here so the eager initial
 * snapshot is delivered before any Compose tree is created, and we never
 * tear it down — process death is the only lifecycle event that matters.
 * `Bridge.attach` is once-and-only-once via precondition, so this is
 * the *only* production caller of `appcoreCreate`.
 */
class AppCoreApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AppModelHolder.start()
    }
}
