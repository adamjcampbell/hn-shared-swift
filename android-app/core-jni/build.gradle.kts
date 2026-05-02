plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

val swiftPackageDir = file("../../AppCore")
val swiftJavaToolDir = "/Users/adam/Developer/tools/swift-java"
val androidNdk = "${System.getenv("HOME")}/Library/Android/sdk/ndk/27.3.13750724"

// Output paths produced by `swift build --swift-sdk aarch64-...-android28`
val swiftBuildArm64 = file("$swiftPackageDir/.build/aarch64-unknown-linux-android28/release")
val swiftSdkRuntime = file("${System.getenv("HOME")}/Library/org.swift.swiftpm/swift-sdks/swift-6.3.1-RELEASE_android.artifactbundle/swift-android/swift-resources/usr/lib/swift-aarch64/android")
val jextractGeneratedJava = file(
    "$swiftPackageDir/.build/plugins/outputs/appcore/AppCoreAndroid/destination/JExtractSwiftPlugin/src/generated/java"
)

tasks.register<Exec>("buildSwiftAarch64") {
    workingDir = swiftPackageDir
    environment("ANDROID_NDK_HOME", androidNdk)
    environment(
        "PATH",
        "$swiftJavaToolDir/.build/release:${System.getenv("PATH")}"
    )
    commandLine(
        "swift", "build",
        "--swift-sdk", "aarch64-unknown-linux-android28",
        "--product", "AppCoreAndroid",
        "--configuration", "release",
        "--disable-sandbox"
    )
}

// Stage all .so files into a single jniLibs/arm64-v8a directory that AGP
// can package into the APK.
val jniLibsStaging = layout.buildDirectory.dir("staged-jni-libs/arm64-v8a")

tasks.register<Copy>("stageJniLibsArm64") {
    dependsOn("buildSwiftAarch64")
    into(jniLibsStaging)
    from(swiftBuildArm64) {
        include("libAppCoreAndroid.so", "libSwiftJava.so")
    }
    from(swiftSdkRuntime) {
        // Bundle every Swift runtime / Foundation .so the SDK ships. We
        // pull in the full set rather than hand-pruning, because each .so
        // can pull in further deps we'd otherwise miss (e.g. libSwiftJava
        // → libswift_Builtin_float). Test/XCTest libs are excluded.
        include("*.so")
        exclude("libXCTest.so", "libTesting.so", "lib_Testing_Foundation.so", "lib_TestingInterop.so")
    }
    from("$androidNdk/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android") {
        include("libc++_shared.so")
    }
}

dependencies {
    api(files("$swiftJavaToolDir/SwiftKitCore/build/libs/swiftkit-core-1.0-SNAPSHOT.jar"))
}

android {
    namespace = "com.example.appcore.bridge"
    compileSdk = 35
    defaultConfig {
        minSdk = 28
        ndk { abiFilters += "arm64-v8a" }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
    kotlinOptions { jvmTarget = "21" }

    sourceSets["main"].apply {
        java.srcDirs(jextractGeneratedJava)
        jniLibs.srcDirs(layout.buildDirectory.dir("staged-jni-libs"))
    }
}

// Make the Android build wait for our .so staging.
tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn("stageJniLibsArm64")
}
