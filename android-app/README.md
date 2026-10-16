# Android app

Native Compose UI backed by the shared Swift core. `preBuild` depends on
`buildSwift`, which runs `runtime/build.py` when its declared inputs change.
It generates stock Skip Swift JNI/Kotlin peers, compiles a Foundation-light
native runtime, and builds JVM runtime jars separately. Gradle consumes these
from the gitignored `build/swift/`; no upstream native AAR payload is used.

## Prerequisites

| Component | Version |
|---|---|
| Skip CLI | 1.8.14 (`brew install skiptools/skip/skip`) |
| Build host | macOS (current script uses macOS Skip and Darwin NDK tools) |
| Swift toolchain | 6.3.1 (`swift` / `swiftc` on PATH) |
| Swift Android SDK | 6.3.1-RELEASE (pinned) |
| Android NDK | 27.3.13750724 |
| Android SDK | platform 36 + cmdline-tools (`minSdk` 28, target 35) |
| JDK | 21 (Android Studio's bundled JBR works) |
| Kotlin | 2.3.0 (declared in root `build.gradle.kts`) |

`local.properties` (gitignored) needs `sdk.dir`:

```
sdk.dir=/Users/<you>/Library/Android/sdk
```

Set `ANDROID_HOME` to the same SDK directory for `build.py` (its default is
`~/Library/Android/sdk`). Install the pinned NDK under `$ANDROID_HOME/ndk/`.
The Swift Android SDK defaults to
`~/.swiftpm/swift-sdks/swift-6.3.1-RELEASE_android.artifactbundle/swift-android`;
`SWIFT_ANDROID_SDK` can override that directory, not the compatibility pin.

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

Gradle tracks Swift sources, the package manifest/lockfile and `runtime/` as
inputs. Environment/toolchain changes may require `:app:buildSwift --rerun-tasks`.

Run `./gradlew :app:connectedDebugAndroidTest` with an arm64 device attached
to check generated observable-property invalidation and Swift MainActor dispatch.
APK `assets/third-party/` contains licenses and the covered runtime source archive;
extract it with a ZIP reader. See `runtime/NOTICE.txt` for details.

## How the model reaches the UI

`App.onCreate` loads `SkipBridge`, `HackerNewsReader` and `MainLooper`,
registers the dispatch main queue with the UI Looper through
`PlatformServices.setupMainLooper()`, then calls `makeAppCore()` once,
holding the resulting `Core` for the process lifetime.
`MainActivity` reads it off the `Application` and passes it into
`StoryScreen`, which consumes `core.model` and `core.commands` and
composes `SendMessageAction(core)` for dispatch. Architecture and
concurrency details live in [`AGENTS.md`](../AGENTS.md).

PlatformSupport delegates GET requests to OkHttp and cancels the same Call
when Swift cancels. URL construction and decoding remain shared Swift.
Language preferences and time formatting use Android APIs; visible strings
remain generated from the single xcstrings catalog, not `strings.xml`.

## Caveats

- **Custom runtime/private SPI.** MainActor still owns production mutations;
  the bootstrap uses private libdispatch eventfd SPI, not a supported Swift
  API. Toolchain upgrades require device isolation/async tests. See
  [runtime notes](runtime/README.md) and
  [ADR-0021](../docs/adr/0021-foundation-light-platform-services.md).
- **JVM compatibility.** Keep Kotlin at the configured 2.3.0 and retain
  `kotlin-reflect`. Release R8 rules preserve JNI/reflection names.
- **`arm64-v8a` only.** The native compiler target and packaging are both
  arm64; x86_64 requires build-script changes, not just an ABI filter.
- **Cancellation boundaries.** Generated Kotlin suspend cancellation does
  not cancel its Swift Task; shared-core HTTP cancellation does cancel OkHttp.
- **Validation.** The native dependency report is not an APK-size measurement
  or evidence of successful launch. Build/device verification is separate.
