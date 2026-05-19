package com.example.hackernewsreader

import android.app.Application
import hacker.news.reader.AppCore
import hacker.news.reader.makeAppCore
import skip.foundation.ProcessInfo

/**
 * Bootstraps SkipFuse's Foundation runtime once per process and builds
 * the single `AppCore` handle the UI consumes. The handle is held for
 * the process lifetime, so the underlying `AppEngine` survives Activity
 * recreation (rotation, theme changes).
 */
class App : Application() {
    lateinit var core: AppCore
        private set

    override fun onCreate() {
        super.onCreate()
        ProcessInfo.launch(applicationContext)
        core = makeAppCore()
    }
}
