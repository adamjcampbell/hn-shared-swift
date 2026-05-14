package com.example.hackernewsreader

import android.app.Application
import skip.foundation.ProcessInfo

/**
 * Bootstraps SkipFuse's Foundation runtime once per process. After this
 * call, every `hacker.news.reader.*` Kotlin class can drive the natively-compiled
 * Swift bridged from `HackerNewsReader/Sources/HackerNewsReader/`.
 */
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        ProcessInfo.launch(applicationContext)
    }
}
