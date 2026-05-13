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
  `RootView` owns the singleton `AppCore` and installs a
  `SendAppEvent` action via `\.sendEvent`. Descendants take
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
- **`AppCore` (workhorse class) is intentionally not bridged.**
  It's internal coordination — `sendEvent`, `scheduleSearchFetch`,
  `makeFetchTask`, the listener Task. `UICore` re-exposes the only
  surface bridging needs (`sendEvent`, `state`, `commands`).

### iOS view layer

(Enforced by `ios-app/AppCoreBridgeExample/RootView.swift` +
`SendAppEvent.swift`.)

- `AppCore` is held only by `RootView`. Below the root, views accept
  `AppState` (the `@Observable final class`) as a parameter; never
  `AppCore` itself.
- Events flow back via `@Environment(\.sendEvent)`, a
  `SendAppEvent` callable struct. The struct is **`Equatable`**
  via nil-parity on the held optional `AppCore`, leaning on the
  invariant that `RootView` constructs exactly one `AppCore` for the
  app's lifetime — "both non-nil" uniquely identifies the installed
  sender and "both nil" is the default env value. Without that
  conformance, SwiftUI's reflection-based environment diff cannot
  compare a closure-holding value, marks the env entry as changed on
  every parent body re-eval, and invalidates every descendant reading
  the key.
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
  Default is `ContinuousClock()`. `makeFetchTask`'s body uses
  `clock.sleep(for:)` for the search debounce. Tests pass a
  `TestClock` (from `pointfreeco/swift-clocks`) and call
  `clock.advance(by:)` to release suspended sleepers atomically.
  The `TestCore.commitSearch(_:clock:)` helper packages the
  listener-debounce-settle pattern (`searchQuery = X` → `settle` →
  advance → `settle`) for tests that only care about the
  post-commit state.
- **`TestCore` installs a `DispatchSerialQueue` as `unownedExecutor`.**
  SE-0392 + Point-Free Video #362 pattern. The `nonisolated func
  settle() async` enqueues a continuation-resume at the back of the
  queue, so awaiting it drains every pending job (listener-Task
  resumption, `isolatedTask` spawns, post-`clock.sleep` fetch
  continuations) deterministically. Replaces `Task.megaYield()`,
  which was probabilistic. Caveat: the queue is strict FIFO, while
  real actors honour task priority — fine because test code has no
  `Task(priority: …)` diversity.
- **`try` (not `try?`) on the debounce `clock.sleep`.** The fetch
  Task body uses `try await clock.sleep(for: debounce)` and lets the
  throw propagate. Swallowing it would let cancelled tasks fall
  through to the client's fetch call.
- **Networking on Android requires `import FoundationNetworking`**
  inside `#if canImport(FoundationNetworking)`. Without the
  conditional import, the cross-compile fails on `URLSession`.
- **`HNClient(fetch:)` is the URL-construction test seam.** Tests
  inject a `@Sendable (URLRequest) async throws -> (Data, URLResponse)`
  closure and capture the request directly — no `URLProtocol`, no
  global mutable state, no `.serialized` suite, and tests run in full
  parallel.

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
- **Architecture: `UICore` shell + `AppCore` workhorse class.**
  `UICore` (production, `@MainActor public struct`) owns `AppState`
  and is the bridged public surface; copying the struct shares the
  underlying `AppState` and `AppCore` references, so `@State` in
  `RootView` is still the single owning location. `AppCore` is a
  non-`Sendable` `final class` — explicitly *not* an actor. Its
  async methods carry `isolation: isolated (any Actor)? = #isolation`
  (SE-0420) and inherit the caller's isolation statically; when
  called from `UICore` they run on `MainActor` and access the
  non-`Sendable` `state` directly via property access (no shim).
  The long-lived `searchQuery` listener Task is spawned via
  `isolatedTask` (a free helper using `sending @isolated(any)`,
  SE-0431 + SE-0430), the only construction that can capture
  non-`Sendable` `self` into an unstructured Task while preserving
  the caller's actor.
- **`sendEvent` is the single orchestration entry.** All four
  fetch flows (feed refresh / feed load-more / search refresh /
  search load-more) plus `toggleRead` / `openStory` live inline as
  switch arms in `AppCore.sendEvent(_:)`. The intentional duplication
  is the point — each arm reads top-to-bottom for its event with
  no helper jumps. The one method that survives outside `sendEvent`
  is `scheduleSearchFetch`, kept private because nesting
  `isolatedTask` inside the listener's `@isolated(any)` body trips
  SE-0461 region isolation; the method-level isolation parameter
  is the load-bearing escape hatch.
- **Tests substitute `TestCore` (per-instance `actor`).**
  Different `TestCore`s run on different executors so tests
  parallelise. `TestCore.run { ... }` is the Point-Free actor-run
  hop for grouped snapshot reads. `TestCore` carries an `isolated
  deinit` (SE-0371, Swift 6.2) that calls `appCore.shutdown()` —
  this breaks the `TaskRegistry → listener-Task → self` cycle when
  each test releases. (Requires macOS 15.4 floor for SE-0371;
  iOS floor stays at 17 because production `UICore` is app-lifetime
  and never deinits.)

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
