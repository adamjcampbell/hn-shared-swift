package com.example.hackernewsreader

import android.app.Application
import hacker.news.reader.Core
import hacker.news.reader.Model
import hacker.news.reader.makeAppCore
import skip.foundation.ProcessInfo

/** `Core` lives in Application scope so its model and task registry survive Activity recreation. */
class App : Application() {
    lateinit var core: Core
        private set

    override fun onCreate() {
        super.onCreate()
        ProcessInfo.launch(applicationContext)
        core = makeAppCore(model = Model())
    }
}
