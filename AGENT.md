# Agent guide

## What this repo is

A reference example showing one Swift `@Observable` model driving native
SwiftUI on iOS and native Jetpack Compose on Android. The Swift core is
compiled natively to `.so` on Android and bridged to Kotlin by
[SkipFuse](https://skip.dev) — Compose reads `@Observable` properties
directly inside `@Composable`s, mutations recompose, `async` is `suspend`,
`AsyncStream` is `Flow`. The example is a small **Hacker News reader**:
front-page stories, search via the Algolia HN API, and a per-story read
indicator. Networking lives in `AppCore` (Swift, `URLSession` via
conditional `import FoundationNetworking` on Android); both UIs only
render the snapshot.

The migration away from a hand-written `swift-java jextract` bridge is
documented in [`docs/skip-fuse-adoption.md`](docs/skip-fuse-adoption.md).
The previous architecture is in [`docs/historical/`](docs/historical/).

## Goals

- One Swift type (`AppCore`) drives both platforms; one `AppEvent`
  enum carries every user-driven mutation.
- iOS: direct `@Observable` + SwiftUI; no bridge in the iOS path.
  `RootView` owns the singleton `AppCore` and installs an
  `AppEventDispatch` action via `\.dispatch`. Descendants take
  `AppState` (the `@Observable final class`) as a parameter.
- Android: bridged via SkipFuse. The Compose UI reads `appModel.state`
  directly — the bridging plugin emits a Kotlin `class AppState` whose
  property getters JNI-call into the Swift `@Observable`'s
  ObservationRegistrar, which SkipFuse routes through Compose's
  `MutableStateBacking` so reads register with the snapshot system and
  mutations recompose.
- Networking lives in Swift: `HNClient` is a `Sendable` struct with two
  `@Sendable` closure properties (`frontPage`, `search`). Tests inject
  closures directly. Production callers use `AppCore()` which wires
  the live `URLSession` HTTP path.
- Modern Swift concurrency: language mode 6,
  `NonisolatedNonsendingByDefault` (SE-0461), `Observations` (SE-0475),
  region-based isolation (SE-0414).

## Non-goals

- **No persistence.** State resets on relaunch. The front page is
  re-fetched on first appear (`.task` on iOS, `LaunchedEffect(Unit)`
  on Android).
- **No localisation, accessibility beyond defaults, multi-window iOS,
  large-screen Android, Mac Catalyst, macOS app.**
- **No support for low-end / Intel Mac AVDs.** Only `arm64-v8a` is
  built.
- **Not a published package.** Nothing here is meant to be
  `swift package add`-ed.

## Non-obvious project rules

### Bridge

- **Adding a new `@Observable` property: add the field on `AppState`.**
  The class already carries `// SKIP @bridgeMembers`, so every new
  public member bridges automatically — no per-field marker, no thunk,
  no Kotlin holder, no `*OnChange` SAM. After Swift changes,
  regenerate the Android AAR with
  `cd AppCore && skip export --debug --no-ios --module AppCore -d
  ../android-app/skip-libs`.
- **`// SKIP @bridgeMembers` (type-level) vs `// SKIP @bridge`
  (per-member).** Bridged structs/classes here use `@bridgeMembers`,
  which bridges every public member of the type with one annotation.
  Reach for per-member `// SKIP @bridge` only when bridging a strict
  subset. Use `// SKIP @nobridge` on a single member to opt it out
  (e.g. `Story.init(hit:isRead:)`, which takes the unbridged `HNHit`).
  **`// SKIP @bridge` at the type level alone is not the same** —
  that produces a Kotlin class with no field accessors (only
  `Identifiable.id` as `ObjectIdentifier`). Always use `@bridgeMembers`
  for whole-type bridging.
- **`AppCore.init()` is the bridged init.** The `init(client:clock:)`
  is a test seam — its parameter types (`HNClient` closure-bag,
  `any Clock<Duration>` existential) don't bridge, and it's
  unmarked.
- **`runFetch` is intentionally not bridged.** It's internal
  coordination called from `dispatch(.refresh)` and
  `runSearchQueryWatcher`; both of those *are* bridged and that's
  enough surface for Android.

### iOS view layer

(Enforced by `ios-app/AppCoreBridgeExample/RootView.swift` +
`AppEventDispatch.swift`.)

- `AppCore` is held only by `RootView`. Below the root, views accept
  `AppState` (the `@Observable final class`) as a parameter; never
  `AppCore` itself.
- Events flow back via `@Environment(\.dispatch)`, an
  `AppEventDispatch` callable struct. The struct is **`Equatable`**
  (`===` on the held `AppCore`); without that conformance, SwiftUI's
  reflection-based environment diff cannot compare a closure-holding
  value, marks the env entry as changed on every parent body re-eval,
  and invalidates every descendant reading the key.
- Don't write `private var foo: some View` on a View. SwiftUI can't
  diff computed properties — they inline into the parent body and
  lose per-section skip behaviour. Extract into a private
  `struct Foo: View`.
- For two-way bindings to `@Observable` properties, use `@Bindable`
  + `$state.foo`. **Never** construct a `Binding(get:set:)` closure
  shim — closures aren't `Hashable` or reference-comparable, so they
  destroy the identity SwiftUI's animation/transaction tracking
  relies on.
- For views that toggle between two states of the *same* surface
  (empty/full, search/main), render the underlying view always and
  reveal the alternate via `.overlay { if cond { … } }`. Top-level
  `if/else` swaps destroy the previous branch and lose its identity
  — scroll position, internal state, animation hooks all reset.
  `.background(.background)` occludes when the overlay needs to fully
  cover.

### Concurrency / testing

- **Inject `clock: any Clock<Duration>` into `AppCore` for tests.**
  Default is `ContinuousClock()`. `runFetch`'s Task body uses
  `clock.sleep(for:)` for the debounce wait. Tests pass a `TestClock`
  (from `pointfreeco/swift-clocks`) and call `clock.advance(by:)` to
  release suspended sleepers atomically.
- **`try` (not `try?`) on the debounce `clock.sleep`.** The Task body
  uses `try await clock.sleep(for: debounce)` and lets the throw
  propagate. Swallowing it would let cancelled tasks fall through to
  the client's fetch call.
- **Networking on Android requires `import FoundationNetworking`**
  inside `#if canImport(FoundationNetworking)`. Without the
  conditional import, the cross-compile fails on `URLSession`.
- **`URLProtocolStub` is `nonisolated(unsafe) static var` storage**
  (acceptable in `Tests/`, forbidden in `Sources/`). Only
  `HNClientTests` touches it, and that suite carries `.serialized`.
  If a future suite starts using `URLProtocolStub` it also needs
  `.serialized`.

### SkipFuse gotchas (full list in
[`docs/skip-fuse-adoption.md`](docs/skip-fuse-adoption.md))

- Kotlin toolchain version must match SkipFuse's exported AAR
  metadata (currently 2.3.0).
- `kotlin-reflect` is required at runtime — `ProcessInfo.launch()`
  uses reflection to invoke the bridge bootstrapper.
- `suspend fun` uses `suspendCoroutine`, not
  `suspendCancellableCoroutine`. Kotlin coroutine cancellation
  doesn't propagate to the underlying Swift Task.
- `AsyncStream<T>` requires `.kotlin()` to convert to `Flow<T>`.
- **`@MainActor`-pinned bridged class + nested actor.** Skip's
  `swift-android-native` calls `AndroidLooper.setupMainLooper()` at
  startup, which drains libdispatch's main queue from Android's
  `ALooper`, so Apple's `MainActor` executes on the main thread on
  Android too. `skipstone` wraps cdecl thunks for `@MainActor`-
  isolated members in `SkipBridge.assumeMainActorUnchecked { ... }`
  (which is `MainActor.assumeIsolated`).
- **Architecture: `AppCore` shell + `AppCoreActor` workhorse.**
  `AppCore` (production, `@MainActor` final class) owns `AppState`
  and is the bridged public surface. `AppCoreActor` is a real
  `actor` whose `unownedExecutor` is borrowed from an `isolation:
  any Actor` init parameter (SE-0392). Production passes
  `MainActor.shared`, so `AppCoreActor`'s executor IS MainActor's.
  All orchestration lives on `AppCoreActor`; it reaches the
  non-`Sendable` `AppState` via an `acquireState` closure the shell
  installs post-init via `handler.assumeIsolated { ... }`. The
  closure wraps mutations in `MainActor.assumeIsolated`, which is a
  runtime no-op given the borrowed executor. Same `AppCoreActor`
  type also serves `TestCore` (in Tests/), a per-instance actor
  that gives tests parallel state-mutation isolation.

## Build & test

```sh
# AppCore unit tests (macOS host).
cd AppCore && \
  JAVA_HOME=/Applications/Android\ Studio.app/Contents/jbr/Contents/Home \
  swift test --disable-sandbox

# iOS app build.
cd ios-app && \
  xcodebuild -project AppCoreBridgeExample.xcodeproj \
    -scheme AppCoreBridgeExample \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation build

# Android: rebuild the AAR after Swift changes, then build the APK.
cd AppCore && \
  skip export --debug --no-ios --module AppCore -d ../android-app/skip-libs
cd ../android-app && \
  JAVA_HOME=/Applications/Android\ Studio.app/Contents/jbr/Contents/Home \
  ./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.example.appcore/.ui.MainActivity
```

The iOS `.xcodeproj` is generated from `ios-app/project.yml` via
`xcodegen` and gitignored. The Android `skip-libs/` directory is also
gitignored — it's a build artefact.
