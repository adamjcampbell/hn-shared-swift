plugins { id("com.android.library") }

val swiftSdk = "/path/to/swift-android-sdk"  // from `swift sdk list`
val ndk = "/path/to/android-ndk-r27d"

tasks.register<Exec>("buildSwiftAarch64") {
    workingDir = file("../../AppCore")
    commandLine(
        "swift", "build",
        "--swift-sdk", "aarch64-unknown-linux-android28",
        "--product", "AppCoreAndroid",
        "--configuration", "release"
    )
}

tasks.register<Exec>("buildSwiftX86_64") {
    workingDir = file("../../AppCore")
    commandLine(
        "swift", "build",
        "--swift-sdk", "x86_64-unknown-linux-android28",
        "--product", "AppCoreAndroid",
        "--configuration", "release"
    )
}

tasks.register<Exec>("jextractAppCoreAndroid") {
    workingDir = file("../../AppCore")
    commandLine(
        "swift-java", "jextract",
        "--mode=jni",
        "--swift-module", "AppCoreAndroid",
        "--package", "com.example.appcore.native",
        "--output-java", "${projectDir}/src/main/java",
        "--output-swift", "${projectDir}/generated-swift"
    )
}

android {
    namespace = "com.example.appcore.native"
    compileSdk = 35
    defaultConfig { minSdk = 28 }

    sourceSets["main"].apply {
        jniLibs.srcDirs("../../AppCore/.build/aarch64-unknown-linux-android28/release",
                        "../../AppCore/.build/x86_64-unknown-linux-android28/release")
    }
}
