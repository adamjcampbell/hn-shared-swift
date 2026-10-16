package com.example.hackernewsreader

import android.app.Application
import com.example.hackernewsreader.bridge.Core

/** `Core` lives in Application scope so its model and task registry survive Activity recreation. */
class App : Application() {
    lateinit var core: Core
        private set

    override fun onCreate() {
        super.onCreate()
        System.loadLibrary("SwiftJava")
        System.loadLibrary("HackerNewsReader")
        System.loadLibrary("MainLooper")
        PlatformServices.setupMainLooper()
        core = Core()
    }
}
