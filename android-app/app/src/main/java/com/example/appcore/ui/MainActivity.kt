package com.example.appcore.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier, color = MaterialTheme.colorScheme.background) {
                    Scaffold { padding ->
                        // padding is intentionally unused; CityScreen draws its own header.
                        CityScreen()
                    }
                }
            }
        }
    }
}
