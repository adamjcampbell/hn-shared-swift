package com.example.hackernewsreader

import android.app.Application
import hacker.news.reader.AppCoreHandle
import hacker.news.reader.makeAppCore
import skip.foundation.ProcessInfo

/**
 * Bootstraps SkipFuse's Foundation runtime once per process and builds
 * the single `AppCoreHandle` the UI consumes. The handle is held for
 * the process lifetime, so the underlying `AppCore` survives Activity
 * recreation (rotation, theme changes).
 */
class App : Application() {
    lateinit var core: AppCoreHandle
        private set

    override fun onCreate() {
        super.onCreate()
        ProcessInfo.launch(applicationContext)
        core = makeAppCore()
    }
}
