plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

kotlin {
    compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21 }
}

val swiftOutput = rootProject.layout.buildDirectory.dir("swift")
val buildSwift = tasks.register<Exec>("buildSwift") {
    description = "Generate Skip peers and build the Foundation-light Android runtime."
    group = "build"
    workingDir(rootProject.projectDir.parentFile)
    commandLine("python3", "android-app/runtime/build.py")
    inputs.dir("../../HackerNewsReader/Sources")
    inputs.file("../../HackerNewsReader/Package.swift")
    inputs.file("../../HackerNewsReader/Package.resolved")
    inputs.dir("../runtime")
    outputs.dir(swiftOutput)
}
tasks.named("preBuild") { dependsOn(buildSwift) }

android {
    namespace = "com.example.hackernewsreader"
    compileSdk = 36
    ndkVersion = "27.3.13750724"
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
    sourceSets.getByName("main") {
        jniLibs.srcDir(swiftOutput.get().dir("jniLibs").asFile)
        assets.srcDir(swiftOutput.get().dir("assets").asFile)
        kotlin.srcDir(swiftOutput.get().dir("generated/HackerNews/kotlin/src/main/kotlin").asFile)
        kotlin.srcDir(swiftOutput.get().dir("generated/HackerNewsReader/kotlin/src/main/kotlin").asFile)
    }
    packaging { jniLibs { useLegacyPackaging = true } }
    buildTypes {
        getByName("release") {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

dependencies {
    implementation(fileTree(swiftOutput.map { it.dir("libs") }) { include("*.jar") })
    implementation("org.jetbrains.kotlin:kotlin-reflect:2.3.0")
    implementation("com.squareup.okhttp3:okhttp:5.3.2")
    implementation("org.commonmark:commonmark:0.28.0")
    implementation("org.commonmark:commonmark-ext-gfm-strikethrough:0.28.0")
    implementation(platform("androidx.compose:compose-bom:2026.05.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3:1.5.0-alpha17")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.browser:browser:1.8.0")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}
