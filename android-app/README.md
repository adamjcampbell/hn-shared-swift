# Android app

An Android Gradle project consuming the SkipFuse-exported
`HackerNewsReader` AAR (and the transitive `HackerNews` AAR) from
`skip-libs/`, which is gitignored. A `skipExport` Gradle task wired
into `preBuild` re-runs `skip export` whenever Swift sources or
`Package.swift` change; otherwise Gradle links the AARs like any
other.

## Prerequisites

| Component | Version |
|---|---|
| Skip CLI | 1.8.14 (`brew install skiptools/skip/skip`) |
| Swift toolchain | 6.3.1+ (managed by Skip's `swiftly` install) |
| Swift Android SDK | 6.3.1+ (managed by Skip CLI) |
| Android NDK | 27.x (Skip CLI auto-installs) |
| Android SDK | platform 28+ + cmdline-tools |
| JDK | 21 (Android Studio's bundled JBR works) |
| Kotlin | 2.3.0 (declared in root `build.gradle.kts`) |

`local.properties` (gitignored) needs `sdk.dir`:

```
sdk.dir=/Users/<you>/Library/Android/sdk
```

## Build & run

```sh
cd android-app

# Boot the AVD if you don't have one running.
$ANDROID_HOME/emulator/emulator -avd Medium_Phone_API_36.1 -no-snapshot-load &
adb wait-for-device

./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.example.hackernewsreader/.ui.MainActivity
```

The first `skipExport` invocation takes a few minutes (Swift toolchain
+ Android cross-compile); subsequent unchanged builds skip it.

## How the model reaches the UI

`App.onCreate` bootstraps the Swift runtime via
`skip.foundation.ProcessInfo.launch(...)` and calls `makeCore()` once,
holding the resulting `Core` for the process lifetime.
`MainActivity` reads it off the `Application` and passes it into
`StoryScreen`, which consumes `core.model`, `core.commands`, and
`core.sendMessage`. Architecture and concurrency details live in
[`AGENTS.md`](../AGENTS.md).

## Caveats

- **`kotlin-reflect` is required.** SkipFuse's `ProcessInfo.launch()`
  uses reflection to invoke the bridge bootstrapper; without it the app
  crashes on first launch with `ClassNotFoundException`.
- **Kotlin version match.** SkipFuse exports AARs with Kotlin 2.3.0
  metadata; the project's Kotlin plugin must be 2.3.0+.
- **`arm64-v8a` only.** Apple Silicon AVDs and physical Pixel/Galaxy
  devices are covered. Add an `x86_64` Skip export + ABI filter for
  Intel-Mac emulators.
- **APK size ≈ 99 MB.** Skip's AARs bundle the Swift stdlib,
  Foundation, and Skip runtime as `.so`s. ProGuard/minify doesn't
  shrink the native side.
