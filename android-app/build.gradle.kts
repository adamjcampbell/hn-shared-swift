// Root build file. Plugin versions are pinned here so subprojects can apply
// them without redeclaring versions.
plugins {
    id("com.android.application") version "8.7.0" apply false
    id("com.android.library") version "8.7.0" apply false
    // Match SkipFuse's exported AAR Kotlin metadata version (2.3.0).
    id("org.jetbrains.kotlin.android") version "2.3.0" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.0" apply false
}
