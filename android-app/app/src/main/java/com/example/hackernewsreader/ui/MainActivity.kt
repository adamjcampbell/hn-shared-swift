package com.example.hackernewsreader.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.example.hackernewsreader.App
import com.example.hackernewsreader.ui.theme.AppTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val core = (application as App).core
        setContent {
            AppTheme {
                StoryScreen(core = core)
            }
        }
    }
}
