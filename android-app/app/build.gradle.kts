plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21
    }
}

android {
    namespace = "com.example.appcore"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.example.appcore"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += "arm64-v8a" }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures { compose = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }


    // SkipFuse-exported AARs each ship the same Swift / Foundation .so files;
    // pick the first occurrence so AGP doesn't fail on duplicates.
    packaging {
        jniLibs {
            keepDebugSymbols.add("**/*.so")
            pickFirsts.add("**/*.so")
            useLegacyPackaging = true
        }
    }
}

dependencies {
    // SkipFuse-bridged AppCore + Skip runtime libraries. Built by
    // `cd ../AppCore && skip export --debug --no-ios --module AppCore -d ../android-app/skip-libs`.
    debugImplementation(fileTree(mapOf(
        "dir" to "../skip-libs",
        "include" to listOf("*.aar"),
    )))
    // SkipFuse's ProcessInfo.launch() uses kotlin.reflect.full to call the
    // bridge initializer reflectively.
    implementation("org.jetbrains.kotlin:kotlin-reflect:2.3.0")

    val composeBom = platform("androidx.compose:compose-bom:2026.04.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3:1.5.0-alpha17")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.browser:browser:1.8.0")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
}
