# Android app

Standard Android Gradle project. Consumes the SkipFuse-bridged
`HackerNewsReader` (+ `HackerNews` SDK target) as a set of `.aar` files
in `skip-libs/` (gitignored). The Swift cross-compile is run by a
small `skipExport` Gradle task (`app/build.gradle.kts`) wired into
`preBuild`: it shells out to the `skip` CLI, drops the resulting AARs
into `skip-libs/`, and Gradle links them like any other AAR.
Gradle's up-to-date check (inputs = Swift sources + `Package.swift`,
output = `HackerNewsReader-debug.aar`) skips the re-export when
nothing changed, so incremental Android builds stay fast and editing
Swift then hitting Run from Android Studio Just Works.

## Modules

- `app/` — the Android application. `MainActivity`, `StoryScreen`
  (Compose UI reading `core.state` directly via SkipFuse-bridged
  Kotlin types in `hacker.news.reader.*` and `hacker.news.*`),
  `App.onCreate` (`skip.foundation.ProcessInfo.launch(...)` to
  bootstrap the Swift runtime), `state/CoreHolder.kt` (process-wide
  `UICore` singleton + a `rememberCore()` Composable).

There is no `core-jni/` module any more — SkipFuse's `skip export`
emits the bridge directly.

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

`local.properties` (gitignored) needs `sdk.dir`. A starter file:

```
sdk.dir=/Users/<you>/Library/Android/sdk
```

## Build & run the APK

`./gradlew :app:assembleDebug` runs `skip export` automatically via
the `skipExport` task on the first build and any time Swift sources
change. The first export takes a few minutes (Swift toolchain +
Android SDK cross-compile); subsequent unchanged builds are a no-op.

```sh
cd android-app

# Boot the AVD if you don't have one running.
$ANDROID_HOME/emulator/emulator -avd Medium_Phone_API_36.1 -no-snapshot-load &
adb wait-for-device

./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.example.hackernewsreader/.ui.MainActivity
```

The exported AARs land in `skip-libs/`:
`HackerNewsReader-debug.aar` and `HackerNews-debug.aar` (transitively
from the package's dependency graph), plus the Skip runtime AARs
(`SkipFoundation-debug.aar`, `SkipModel-debug.aar`, etc.). Each AAR
contains the natively-compiled Swift `.so` libraries for `arm64-v8a`
plus the bridged Kotlin classes.

To run the export by hand (e.g. to refresh `skip-libs/` without a full
Gradle build):

```sh
cd ../HackerNewsReader
skip export --debug --no-ios --module HackerNewsReader -d ../android-app/skip-libs
```

## Caveats

- **`kotlin-reflect` is required.** SkipFuse's `ProcessInfo.launch()`
  uses `kotlin.reflect.full.KClasses` to invoke the bridge
  bootstrapper. The dependency is wired in `app/build.gradle.kts`;
  without it the app crashes on first launch with
  `ClassNotFoundException`.
- **Kotlin version match.** SkipFuse exports AARs with Kotlin 2.3.0
  metadata. The android-app's Kotlin plugin must be 2.3.0+ — root
  `build.gradle.kts` pins this.
- **Architectures.** Only `arm64-v8a` is built. Apple Silicon AVDs use
  arm64; physical Pixel/Galaxy devices are arm64-v8a. Add an `x86_64`
  Skip export + ABI filter for Intel-Mac emulators.
- **APK size.** Debug APK ≈ 99 MB — Skip's exported AARs bundle the
  Swift stdlib + Foundation + Skip runtime as `.so`s. Release builds
  with ProGuard/minify don't shrink the native side; this is the
  cost of native Swift on Android.

## Tests

Bridge regression tests for the new SkipFuse path are not in this
repo yet. The previous `BridgePerfTest` (cold-start + JNI latency
benchmarks for the deleted `appcoreObserve*` thunks) was removed
during the migration; an equivalent suite can be re-added once the
SkipFuse surface is stable enough for it to be useful.
