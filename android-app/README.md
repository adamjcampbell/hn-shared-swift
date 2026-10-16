# Android app

Native Compose UI backed by the shared Swift core. `preBuild` depends on
`buildSwift`, which runs `runtime/build.py` when its declared inputs change.
It generates model adapters with SwiftParser, then uses official Swift–Java
to generate synchronous JNI thunks and typed Java peers. Gradle consumes the
Foundation-light native libraries, Kotlin adapters and `SwiftJava.jar` from
the gitignored `build/swift/`; no upstream native AAR payload is used.
Debug and R8 release builds and arm64 emulator checks are recorded in
[ADR-0022](../docs/adr/0022-official-swift-java-bridge.md).

## Prerequisites

| Component | Version |
|---|---|
| swift-java | `301e3da710ede7af93e798f1ce1c7950715a5748` |
| swift-java-jni-core | `b440a0be98381550cf189c903782e817619ffa05` (lockfile) |
| Build host | macOS (current script uses Xcode host libraries and Darwin NDK tools) |
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

No Skip CLI, Skip dependencies, patches, old SwiftJNI or kotlin-reflect are needed.
`build.py` builds the pinned `swift-java` tool unless `SWIFT_JAVA_TOOL` is set;
any override must use that same revision. Environment/toolchain changes may
require `:app:buildSwift --rerun-tasks`.

Run `ANDROID_SERIAL=<serial> ./gradlew :app:connectedDebugAndroidTest` with
an arm64 device attached to check observable-property invalidation, Swift
MainActor dispatch, explicit close/value copies and coroutine cancellation.
APK `assets/third-party/` contains licenses, notices and all build-root lockfiles.
See `runtime/NOTICE.txt` for upstream source references.

## How the model reaches the UI

`App.onCreate` loads `SwiftJava`, `HackerNewsReader` and `MainLooper`,
registers the dispatch main queue with the UI Looper through
`PlatformServices.setupMainLooper()`, then constructs Kotlin `Core` once.
It owns an official Java `AndroidReader` peer over Swift's `makeAppCore()`
for the Application lifetime and explicitly closes native resources on `close()`.
`MainActivity` reads it off the `Application` and passes it into
`StoryScreen`, which consumes `core.model` and `core.commands` and
composes `SendMessageAction(core)` for dispatch. Architecture and
concurrency details live in [`AGENTS.md`](../AGENTS.md).

The generator discovers public `Model` fields and emits MainActor-checked
accessors, Observation invalidation subscriptions and immutable value projections.
Kotlin revision counters trigger Compose reads of Swift's latest state, not
snapshot-versioned state. Native values are copied within confined arenas and
disposed; dates become epoch-seconds `Double`. Kotlin is not a second mutable
source of truth.

Messages are copied synchronously before Swift suspends. Native task handles
and `suspendCancellableCoroutine` propagate cancellation to Swift and the fetch;
there is no raw-peer async future path. Typed Java command peers become Kotlin
values in `Core.commands`, a Flow. The native command pump survives Activity
recollection until Core closes; cancelling a collector removes its subscription,
not the pump. Only one command consumer is supported.

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
- **JVM compatibility.** Keep Kotlin at the configured 2.3.0. Release R8
  rules preserve JNI names. App, Observation and core code remain Swift 6;
  only generated synchronous JNI thunks use Swift 5 mode.
- **`arm64-v8a` only.** The native compiler target and packaging are both
  arm64; x86_64 requires build-script changes, not just an ABI filter.
- **Validation.** The native dependency report is not an APK-size measurement.
  ADR-0022 records separate APK measurements and emulator launch checks, not
  physical-device compatibility or resident memory.
