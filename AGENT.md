# Agent guide

## What this repo is

A reference example showing one Swift `@Observable` model shared between an
iOS SwiftUI app and an Android Jetpack Compose app, **without Skip**, on the
official Swift Android SDK + `swift-java jextract --mode=jni`. The Swift
code is the source of truth; both UIs are thin renderers. The example is
a small **Hacker News reader**: front-page stories, search via the Algolia
HN API, and a per-story read indicator. Networking lives in `AppCore` (Swift
side, `URLSession` via conditional `import FoundationNetworking` on Android);
both UIs only render the snapshot.

## Goals

- One Swift type (`AppModel`) drives both platforms; one Codable
  `AppEvent` enum carries every user-driven mutation.
- iOS: direct `@Observable` + SwiftUI; no JNI, no JSON. `RootView` owns
  the singleton `AppModel` and installs an `AppEventDispatch` action via
  `\.dispatch`. Descendant views receive narrow `AppState` slices (often
  just the fields they read) and fire events through `\.dispatch` — the
  model is invisible below the root.
- Android: `AndroidBridge` actor + `Observations` task → JSON snapshot →
  Java callback → Compose recomposition. Mutations go through one JNI
  entry point: `appcoreDispatch(eventJSON:)`.
- Networking lives in Swift: `HNClient` is a `Sendable` struct with
  two `@Sendable` closure properties (`frontPage`, `search`), injected
  into `AppModel.init`. The struct shape is the natural mock point —
  tests inject closures directly. Production callers use the no-arg
  `init()`, which wires the closures to live HTTP via `URLSession`.
  `AppModel.runFetch` cancel-and-replaces a single `searchTask:
  Task<[Story], Error>?` — the latest dispatch always wins; cancelled
  predecessors throw `CancellationError` from `clock.sleep` or the
  fetch and are skipped at the dispatch arm's `catch`.
- Modern Swift concurrency: language mode 6,
  `NonisolatedNonsendingByDefault` (SE-0461), `Observations` (SE-0475),
  region-based isolation (SE-0414).

## Non-goals

Per spec §12 plus what verification surfaced:

- **No persistence.** State resets on relaunch. AppCore-owned state
  (`stories`, `read`, `searchQuery`, …) intentionally resets on process
  death; the front page is re-fetched on first appear via the platform's
  init effect (`.task` on iOS, `LaunchedEffect(Unit)` on Android).
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

- **Never use `@unchecked Sendable` or `nonisolated(unsafe)` in
  `AppCore/Sources/`.** The architecture is built around proper isolation
  (actors, value types, single-instance singletons), and a hand-rolled
  unsafe escape hatch usually means the design is wrong. The single
  exception is `Sources/AppCoreAndroid/JavaInterop.swift`, which adopts
  `@unchecked Sendable` for the jextract-generated `JavaSnapshotSink`
  wrapper — swift-java does not yet mark `@JavaInterface` types as
  `Sendable`, but the underlying JNI handle is safe to share. If you add
  another exception, document the why in the same file.
- `AppCoreAndroid` user-facing sources (`AppCoreNative.swift`,
  `AndroidBridge.swift`) are *not* wrapped in `#if canImport(Android)`
  because jextract runs on the macOS host and silently skips functions
  that sit inside such a guard — the generated Java module class would
  end up with no `appcoreCreate` / `appcoreToggleFavorite` / … methods.
  AndroidBridge gates only its `Observations` usage on
  `canImport(Android)` since `Observations` (SE-0475) requires a Swift
  toolchain newer than this package's macOS deployment target; on macOS
  the actor still compiles as a no-op.
- There is exactly one `AppModel` per process. `AppCoreNative` exposes a
  global `AndroidBridge.shared` singleton actor and the entry points
  (`appcoreCreate`, `appcoreDispatch`, `appcoreDestroy`) operate on it
  without handles. The Kotlin side initialises `AppModelHolder` once from
  `AppCoreApplication.onCreate`; `appcoreCreate(sink:)` is idempotent
  (replaces the prior sink) so per-test attach/detach in `BridgePerfTest`
  works without a reset hook.
- The value-type snapshot is `AppState` (renamed from `Snapshot` so the
  property reads as `appModel.state: AppState`). Don't rename it back to
  `State` — that collides with SwiftUI's `@State` property wrapper in
  iOS code.
- **`AndroidBridge` deduplicates emissions before the JNI hop.** The
  observation `Task` body holds a local `var lastDeliveredState:
  AppState?` and skips `sink.deliver` when the new state equals the
  prior one. `Observations` starts a transaction on every `willSet`
  regardless of value-equality, so without this guard a redundant
  write (e.g. `state.isLoading = true` when already true) would
  JSON-encode and JNI-hop for nothing. Compose's
  `mutableStateOf<AppState?>` saves the recompose either way, but the
  wire round-trip costs ~100 µs per skipped emission. Holding a
  ~10–30 KB copy of the prior state is the cheap end of the trade.
  The dedup state lives inside the Task closure rather than on the
  actor — `attach` cancels and respawns the Task, so a fresh sink
  gets a fresh comparison automatically.
- **Debouncing lives inside `AppModel.dispatch`, not the platform UI.**
  `.setSearchQuery` cancel-and-replaces a stored
  `searchTask: Task<[Story], Error>?`. The platform UI just forwards
  every keystroke as `.setSearchQuery`. The Task body captures only
  Sendable values (`[client, clock, query]`) — never `self` — and
  returns `[Story]` or throws. The dispatch arm awaits with `try` and
  commits the result on the caller's actor. This sidesteps SE-0461's
  "unstructured Task in nonisolated function captures non-Sendable
  self" hole: there's no self capture, so there's no region transfer
  to fail. State mutations happen back in the dispatch arm, not in
  the Task.
- **Inject `clock: any Clock<Duration>` into `AppModel` for tests.**
  Default is `ContinuousClock()`. `runFetch`'s Task body uses
  `clock.sleep(for:)` for the debounce wait. Tests pass a `TestClock`
  (from `pointfreeco/swift-clocks`) and call `clock.advance(by:)` to
  release suspended sleepers atomically — no real-clock waiting. Two
  cancel-and-replace tests
  (`setSearchQuery_coalescesRapidKeystrokes`,
  `refresh_cancelsPendingDebounce`) run in <1 ms each.
- **`try` (not `try?`) on the debounce `clock.sleep`.** The Task body
  uses `try await clock.sleep(for: debounce)` and lets the throw
  propagate. Swallowing it with `try?` would let cancelled tasks fall
  through to the client's fetch call, and a test-mock closure that
  doesn't honor cancellation would then succeed for the cancelled
  query and commit stale data. `URLSession.data` honors cancellation
  in production, but the mocks can't be expected to as faithfully —
  letting the throw propagate makes cancel-and-replace robust against
  any client implementation.
- **Networking on Android requires `import FoundationNetworking`**
  inside `#if canImport(FoundationNetworking)`. On Apple platforms
  `URLSession` is part of `Foundation`; on swift-corelibs-foundation
  (Android/Linux) it's a separate sub-component. Without the
  conditional import, `swift build --swift-sdk aarch64-…-android28`
  fails on `URLSession`.
- **`URLSessionConfiguration.waitsForConnectivity` is read-only on
  swift-corelibs-foundation.** Don't set it; the default (`false`) is
  what we want anyway.
- Adding a new mutation requires (a) a new `case` on `AppEvent` (Swift)
  — `Codable` is generated by MetaCodable's `@Codable` + `@CodedAt("type")`
  on the enum, so no per-case annotation is needed when the case name
  equals the wire string; add `@CodedAs("…")` per case only if they need
  to differ — (b) a `switch` arm in `AppModel.dispatch`, and (c) a matching
  `@SerialName`'d variant on Kotlin's `sealed class AppEvent` in
  `AppModelHolder.kt`. No new JNI entry point.
- **`URLProtocolStub` is `nonisolated(unsafe) static var` storage**
  (acceptable in `Tests/`, forbidden in `Sources/`). Only `HNClientTests`
  touches it, and that suite carries `.serialized` — no other suite
  references it. If a future suite starts using `URLProtocolStub` it
  also needs `.serialized`, AND the runner needs `--no-parallel`,
  because `.serialized` only serialises within a single suite (Swift
  Testing parallelises across suites by default).
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
- The iOS target builds in **Swift 6** with **Approachable Concurrency**
  enabled (`SWIFT_APPROACHABLE_CONCURRENCY = YES`), default actor
  isolation **explicitly `nonisolated`** (not `MainActor` — to keep the
  cross-platform "isolation determined by the call site" rule from
  spec §2), and `SWIFT_STRICT_CONCURRENCY = complete`. The combination
  gives us SE-0461 (`NonisolatedNonsendingByDefault`) so `async`
  functions inherit the caller's actor — which means `appModel`'s
  `dispatch(_:)` runs on `MainActor` when called from a SwiftUI body
  without any explicit annotation. The one place that *does* need
  explicit `@MainActor` is `AppEventDispatch`'s perform paths
  (`callAsFunction`, `run`, and the inner `Task`) because they capture
  the non-`Sendable` `AppModel` into a sending `Task` closure; pinning
  the call site, capture, and Task body to MainActor satisfies region
  isolation without crossing actors.
- **iOS view-layer rules** (enforced by `ios-app/AppCoreBridgeExample/RootView.swift` + `AppEventDispatch.swift`):
  - `AppModel` is held only by `RootView`. Below the root, views accept
    `AppState` (or specific slices like `cities` / `favorites`) as
    parameters; never `AppModel` itself.
  - Events flow back via `@Environment(\.dispatch)`, an
    `AppEventDispatch` callable struct in the shape of SwiftUI's
    `DismissAction`. The struct is **`Equatable`** (`===` on the held
    `AppModel`); without that conformance, SwiftUI's reflection-based
    environment diff cannot compare a closure-holding value, marks the
    env entry as changed on every parent body re-eval, and invalidates
    every descendant reading the key. If you add a similar capability,
    use the same shape: callable struct + stable `Equatable` identity.
  - Don't write `private var foo: some View` on a View. SwiftUI can't
    diff computed properties — they inline into the parent body and
    lose per-section skip behaviour. Extract into a private `struct
    Foo: View` so the child gets its own diffing checkpoint, and store
    only the fields the body reads (narrow inputs let SwiftUI skip the
    body when unrelated `AppState` fields mutate).
  - For views that toggle between two states of the *same* surface
    (empty/full, search/main), render the underlying view always and
    reveal the alternate via `.overlay { if cond { … } }`. Top-level
    `if/else` swaps destroy the previous branch and lose its identity
    — scroll position, internal state, and animation hooks all reset.
    Apple's WWDC21 *Craft search experiences in SwiftUI* recommends
    overlay specifically so the main UI stays mounted across a search
    interaction. Reserve `if/else` at the top of `body` for *different*
    surfaces (logged-out vs logged-in, list vs detail). When the
    overlay needs to fully occlude what's behind it, use
    `.background(.background)` — the iOS 17+ `BackgroundStyle`
    `ShapeStyle`, no UIKit bridge.

## When making changes

- Verify both platforms still build:
  - `cd AppCore && JAVA_HOME=/Applications/Android\ Studio.app/Contents/jbr/Contents/Home swift test --disable-sandbox`
  - `cd ios-app && xcodebuild -project AppCoreBridgeExample.xcodeproj -scheme AppCoreBridgeExample -destination 'platform=iOS Simulator,name=iPhone 17' build`
  - `cd android-app && ./gradlew :app:assembleDebug && ./gradlew :app:connectedDebugAndroidTest`
- The `BridgePerfTest.a_coldStart_…` regression test is the load-bearing
  guard against accidentally breaking initial-snapshot delivery.
