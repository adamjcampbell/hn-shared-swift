package com.example.hackernewsreader

import android.app.Application
import hacker.news.reader.Core
import hacker.news.reader.makeCore
import skip.foundation.ProcessInfo

/**
 * Bootstraps SkipFuse's Foundation runtime once per process and builds
 * the single `Core` handle the UI consumes. The handle is held for
 * the process lifetime, so the underlying `Engine` survives Activity
 * recreation (rotation, theme changes).
 */
class App : Application() {
    lateinit var core: Core
        private set

    override fun onCreate() {
        super.onCreate()
        ProcessInfo.launch(applicationContext)
        core = makeCore()
    }
}
