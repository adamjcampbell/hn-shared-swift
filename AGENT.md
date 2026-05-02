# Agent guide

## What this repo is

A reference example showing one Swift `@Observable` model shared between an
iOS SwiftUI app and an Android Jetpack Compose app, **without Skip**, on the
official Swift Android SDK + `swift-java jextract --mode=jni`. The Swift
code is the source of truth; both UIs are thin renderers.

## Goals

- One Swift type (`AppState`) drives both platforms.
- iOS: direct `@Observable` + SwiftUI; no JNI, no JSON.
- Android: `AndroidBridge` actor + `Observations` task → JSON snapshot →
  Java callback → Compose recomposition.
- Modern Swift concurrency: language mode 6,
  `NonisolatedNonsendingByDefault` (SE-0461), `Observations` (SE-0475),
  region-based isolation (SE-0414).

## Non-goals

Per spec §12 plus what verification surfaced:

- **No networking.** `refresh()` is `Task.sleep(for: .seconds(1))`.
- **No persistence.** State resets on relaunch.
- **No localisation, accessibility beyond defaults, multi-window iOS,
  large-screen Android, Mac Catalyst, macOS app.**
- **No Skip.** The whole point is doing this without Skip.
- **No production-grade JNI safety.** jextract handles ref counting,
  attach/detach, exception bridging.
- **No typed JNI marshaling for the snapshot.** JSON is fast enough at
  the demo's payload scale (340 B). Swap if/when payload grows or
  jextract struct support matures.
- **No support for low-end / Intel Mac AVDs.** Only arm64-v8a is built.
- **Not a published package.** `swift-java` is a path dependency; nothing
  here is meant to be `swift package add`-ed.
- **Not a test of `Observations`'s cold-start emission semantics.** It
  doesn't emit on cold start; we deliver the initial snapshot eagerly
  (see `appcoreCreate` in `AppCoreNative.swift`).

## Non-obvious project rules

- `AppCoreAndroid` user-facing sources (`AppCoreNative.swift`,
  `AndroidBridge.swift`) are wrapped in `#if canImport(Android)` so the
  module is effectively empty on macOS. The `JExtractSwiftPlugin` still
  runs there but its generated glue references no user code, so linking
  succeeds.
- Both `swift build` and `swift test` on macOS need
  `--disable-sandbox` and `JAVA_HOME` pointing at a JDK 17+ install
  (Android Studio's JBR works), because the plugin's Java-callback
  phase shells out to Gradle, which the SwiftPM plugin sandbox would
  deny network for and the system `/usr/bin/javac` (JDK 11 on this
  host) would reject.
- The Android build similarly passes `--disable-sandbox` to `swift
  build` from inside `core-jni/build.gradle.kts`.
- `BridgePerfTest`'s cold-start test (`a_coldStart_…`) uses an `a_`
  prefix to run first under `@FixMethodOrder(NAME_ASCENDING)` — earlier
  toggling tests would mask a regression of the eager-delivery path.
- The iOS `.xcodeproj` is generated from `ios-app/project.yml` via
  `xcodegen` and gitignored.

## When making changes

- Verify both platforms still build:
  - `cd AppCore && JAVA_HOME=/Applications/Android\ Studio.app/Contents/jbr/Contents/Home swift test --disable-sandbox`
  - `cd ios-app && xcodebuild -project AppCoreBridgeExample.xcodeproj -scheme AppCoreBridgeExample -destination 'platform=iOS Simulator,name=iPhone 17' build`
  - `cd android-app && ./gradlew :app:assembleDebug && ./gradlew :app:connectedDebugAndroidTest`
- The `BridgePerfTest.a_coldStart_…` regression test is the load-bearing
  guard against accidentally breaking initial-snapshot delivery.
