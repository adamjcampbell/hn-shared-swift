# Cross-platform `@Observable` ↔ Compose Bridge

A minimal, runnable example of a single Swift `@Observable` model shared
between an iOS SwiftUI app and an Android Jetpack Compose app, **without
Skip**, on the official Swift Android SDK. The example is a small Hacker
News reader: front-page stories, server-side search via the free
[Algolia HN API](https://hn.algolia.com/api), and a per-story read
indicator. Networking lives in Swift (`URLSession` via conditional
`import FoundationNetworking` on Android); both UIs only render the
snapshot.

[`swift-observable-compose-bridge-spec.md`](swift-observable-compose-bridge-spec.md)
is the original implementation spec. [`AGENT.md`](AGENT.md) lists project
goals and non-goals at a glance.

## Layout

- `AppCore/` — SwiftPM package with three targets:
  - `AppCore` — the cross-platform `@Observable` model (`AppState`, `City`,
    `Snapshot`). Consumed directly by iOS.
  - `AppCoreAndroid` — Android-only JNI bridge. Friendly Swift functions plus
    an `AndroidBridge` actor that owns an `AppState` and an `Observations`
    task; jextract turns it into a `.so` + Java surface.
  - `AppCoreTests` — XCTest/Swift Testing target running on macOS.
- `ios-app/` — SwiftUI app generated from `project.yml` via `xcodegen`.
- `android-app/` — Gradle project that builds `AppCoreAndroid` for Android
  via the Swift Android SDK and consumes it through
  `swift-java jextract --mode=jni`.

## Verified

| Surface | Tested how | Status |
|---|---|---|
| `AppCore` SwiftPM target | `swift test --disable-sandbox` on macOS (JAVA_HOME=JDK 21), 17/17 tests pass in ~10 ms | ✅ |
| iOS app | `xcodebuild` for `iPhone 17 / iOS 26.4.1` simulator | ✅ |
| Android: build | `./gradlew :app:assembleDebug` produces `app-debug.apk` | ✅ |
| Android: cold start | `BridgePerfTest.a_coldStart_…` regression test (50 ms timeout) | ✅ |
| Performance | See `BridgePerfTest`: sync JNI ~625 ns, full round-trip ~100 µs median | (carries over from pre-networking baseline) |

## Spec deviations

The spec was written before the actual `swift-java jextract` shape was
known and before networking was added. The codebase now reflects a few
real differences from spec §1–§13:

0. **Networking is in.** Spec §12 listed "no networking" as a non-goal.
   The example now fetches Hacker News stories via Algolia HN search
   with `URLSession` in `AppCore`. `HNClient` is a `Sendable` closure-
   struct so tests inject mock closures directly. `searchQuery` is
   per-property bridged rather than dispatched as an event: iOS uses
   `@Bindable` + `$state.searchQuery`, Android uses a per-property
   JNI setter (`appcoreSetSearchQuery`) plus a matching push sink.
   `AppModel.runSearchQueryWatcher` iterates `state.observe(\.searchQuery)`
   (a small `AsyncSequence` over a single `@Observable` key path,
   modelled after `Observations`) and on every willSet calls
   `runFetch(debounce:)`, which cancel-and-replaces a `Task<[Story], Error>?`
   that sleeps the debounce window then issues the fetch.
   `CancellationError` flows through the standard path; `URLError(.cancelled)`
   is normalised to `CancellationError` so superseded fetches don't
   surface as transient errors. `AppModel` takes a `Clock` so tests
   use `TestClock` for deterministic timing.

1. **`AppCoreAndroid` sources are wrapped in `#if canImport(Android)`** so
   the target compiles to an empty module on macOS. Lets us run
   `swift build`/`swift test` against the package on macOS without the
   Platform.swift `#error` aborting the build.
2. **Almost no hand-written `@_cdecl` annotations.** Spec §5.7 sketched a
   `@_cdecl("Java_…")` design; in reality `swift-java`'s `JExtractSwiftPlugin`
   is a SwiftPM build-tool plugin driven by `swift-java.config`, and it
   generates both the Java surface *and* the `@_cdecl` glue from friendly
   Swift signatures. `JNIBridge.swift` was deleted; `AppCoreNative.swift`
   exposes `appcoreCreate / appcoreDispatch / appcoreSetSearchQuery /
   appcoreDestroy` as plain public functions. The single hand-written
   `@_cdecl` is `Java_com_example_appcore_bridge_LooperPoster_runSwiftJob`
   in `LooperExecutor.swift` — the upcall that runs a queued Swift job
   on Android's main `Looper`. jextract doesn't (yet) generate this
   shape, so the JNI naming is hand-mangled.
3. **`enableJavaCallbacks: true`** turns the Swift `protocol SnapshotSink`
   into a Java interface; Kotlin's `AppStateHolder` implements it directly.
   No hand-rolled Swift→Java JNI calls.
4. **`native` is a Java reserved keyword** so the generated package is
   `com.example.appcore.bridge`, not `…native` as the spec suggested.
5. **Initial snapshot is delivered eagerly** from `appcoreCreate` because
   `Observations` (SE-0475) only emits *after* a mutation. Without this,
   Compose renders empty until the user toggles or refreshes.
6. **`swift-java` is a path dependency** at
   `/Users/adam/Developer/tools/swift-java`, not a remote git URL. SwiftPM
   correctly omits it from iOS resolution because no iOS target uses it.
7. **iOS view layer evolved past spec §7.** The spec sketches a
   `ContentView` that calls `appState.toggleFavorite(...)` directly and
   pushes `AppModel` into descendant views. The shipped tree is
   `RootView` → `CitiesScreen` → `CitiesContent` → `SearchResults` /
   `FullCitiesList` → `CityRows`/`FavoritesSummary` → `CityRow`. Only
   `RootView` holds `AppModel`; below it, views take narrow `AppState`
   slices and dispatch via `@Environment(\.dispatch)` (an
   `AppEventDispatch` `Equatable` callable struct — closures held in
   `EnvironmentValues` without `Equatable` conformance defeat SwiftUI's
   diff). Computed `some View` properties were also extracted into
   proper View structs so SwiftUI gets per-section diffing checkpoints.
   See `ios-app/AppCoreBridgeExample/RootView.swift` +
   `AppEventDispatch.swift`, and `AGENT.md`'s iOS view-layer rules.

## Toolchain

| Component | Version used |
|---|---|
| Swift | 6.3.1 |
| Swift Android SDK | 6.3.1 (`swift sdk install …`) |
| Android NDK | 27.3.13750724 |
| Android cmdline-tools | 13114758 |
| Android SDK + emulator | from Android Studio bundle |
| JDK | 21 (Android Studio JBR) |
| `swift-java` | built from main, ~April 2026 |
| Xcode | 26.4.1 |
| `xcodegen` | latest from Homebrew |

## Quick start

iOS: see [`ios-app/README.md`](ios-app/README.md).
Android: see [`android-app/README.md`](android-app/README.md).
