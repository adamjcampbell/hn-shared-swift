package com.example.hackernewsreader.ui

import android.content.Context
import androidx.core.net.toUri
import androidx.browser.customtabs.CustomTabsIntent

fun Context.launchCustomTab(url: String) {
    CustomTabsIntent.Builder()
        .setShowTitle(true)
        .build()
        .launchUrl(this, url.toUri())
}
