package com.example.appcore

import android.app.Application
import skip.foundation.ProcessInfo

/**
 * Bootstraps SkipFuse's Foundation runtime once per process. After this
 * call, every `app.core.*` Kotlin class can drive the natively-compiled
 * Swift bridged from `AppCore/Sources/AppCore/`.
 */
class AppCoreApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        ProcessInfo.launch(applicationContext)
    }
}
