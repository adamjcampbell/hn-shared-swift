package com.example.hackernewsreader

import android.app.Application
import hacker.news.reader.Core
import hacker.news.reader.makeCore
import skip.foundation.ProcessInfo

/** `Core` lives in Application scope so the underlying `Engine` survives Activity recreation. */
class App : Application() {
    lateinit var core: Core
        private set

    override fun onCreate() {
        super.onCreate()
        ProcessInfo.launch(applicationContext)
        core = makeCore()
    }
}
