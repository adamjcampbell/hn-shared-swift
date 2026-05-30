import java.io.File

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21
    }
}

android {
    namespace = "com.example.hackernewsreader"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.example.hackernewsreader"
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

// Re-export HackerNewsReader's Swift package as Android AARs into
// ../skip-libs before each Gradle build, so editing Swift in
// HackerNewsReader/Sources and running from Android Studio Just Works
// without a manual `skip export` step. Gradle's up-to-date check
// (inputs = Swift sources + Package.swift, output =
// HackerNewsReader-debug.aar; the HackerNews dependency target is
// transitively re-exported alongside) skips the re-export when nothing
// changed, so incremental builds stay fast.
//
// This isn't a documented Skip workflow — the canonical loop is to
// drive builds from Xcode, which orchestrates Gradle for the Android
// side. We use a split iOS/Android repo layout, so we wire the
// missing piece in ourselves.
// Resolve `skip` at configuration time: Android Studio's Gradle daemon
// doesn't inherit shell PATH, so `commandLine("skip", ...)` fails to
// locate the Homebrew install. Probe in order: explicit override
// (SKIP_BIN), the user's login-shell PATH (picks up MacPorts / Nix /
// asdf / fnm-style installs), known Homebrew locations, then bare
// "skip" as a last resort.
val skipBinary: String = run {
    fun viaLoginShell(): String? = try {
        val proc = ProcessBuilder("bash", "-lc", "command -v skip").start()
        val output = proc.inputStream.bufferedReader().readText().trim()
        if (proc.waitFor() == 0 && output.isNotEmpty()) output else null
    } catch (_: Exception) { null }

    val candidates = listOfNotNull(
        System.getenv("SKIP_BIN"),
        viaLoginShell(),
        "/opt/homebrew/bin/skip",    // Apple Silicon Homebrew
        "/usr/local/bin/skip",        // Intel Homebrew
        "${System.getProperty("user.home")}/.local/bin/skip",
    )
    candidates.firstOrNull { File(it).canExecute() } ?: "skip"
}

val skipExport = tasks.register<Exec>("skipExport") {
    description = "Re-export HackerNewsReader as an Android AAR via the skip CLI."
    group = "build"
    val readerDir = rootProject.layout.projectDirectory.dir("../HackerNewsReader")
    val skipLibsDir = rootProject.layout.projectDirectory.dir("skip-libs")
    workingDir = readerDir.asFile
    commandLine(
        skipBinary, "export",
        "--debug", "--no-ios",
        "--module", "HackerNewsReader",
        "-d", "../android-app/skip-libs",
    )
    inputs.files(fileTree(readerDir.dir("Sources")) { include("**/*.swift") })
        .withPropertyName("readerSources")
        .withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.file(readerDir.file("Package.swift"))
        .withPropertyName("packageManifest")
    outputs.file(skipLibsDir.file("HackerNewsReader-debug.aar"))
        .withPropertyName("readerAar")
}

tasks.named("preBuild") { dependsOn(skipExport) }

dependencies {
    // SkipFuse-bridged HackerNewsReader (and its HackerNews dependency)
    // + Skip runtime libraries. Re-exported by the `skipExport` task
    // above on each build; the canonical manual command is
    // `cd ../HackerNewsReader && skip export --debug --no-ios --module HackerNewsReader -d ../android-app/skip-libs`.
    debugImplementation(fileTree(mapOf(
        "dir" to "../skip-libs",
        "include" to listOf("*.aar"),
    )))
    // SkipFuse's ProcessInfo.launch() uses kotlin.reflect.full to call the
    // bridge initializer reflectively.
    implementation("org.jetbrains.kotlin:kotlin-reflect:2.3.0")

    // SkipFoundation's Bundle.localizedString routes every value through
    // commonmark to render Markdown-flavored xcstrings entries. The AAR
    // declares these as implementation() deps in its own build, but
    // fileTree(...) consumption strips pom-declared transitives, so we
    // mirror Skip's declaration explicitly.
    implementation("org.commonmark:commonmark:0.28.0")
    implementation("org.commonmark:commonmark-ext-gfm-strikethrough:0.28.0")

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
