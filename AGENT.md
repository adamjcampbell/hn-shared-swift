# Agent guide

## What this repo is

A reference example showing one Swift `@Observable` model driving native
SwiftUI on iOS and native Jetpack Compose on Android. The Swift core is
compiled natively to `.so` on Android and bridged to Kotlin by
[SkipFuse](https://skip.dev) — Compose reads `@Observable` properties
directly inside `@Composable`s, mutations recompose, `async` is `suspend`,
`AsyncStream` is `Flow`. The example is a small **Hacker News reader**:
front-page stories (live-ranked via the [official HN Firebase
API](https://github.com/HackerNews/API)), search via the Algolia HN API
(Firebase has no text-search endpoint), and a per-story read indicator.

The Swift package splits into two targets:
- `HackerNews` — API client + entity types (`Client`, `Story`, `Page`).
- `HackerNewsReader` — reducer + state (`AppCore`, `AppState`,
  `StoryRow`, `LoadableStories`) and the bridged module surface in
  `Core.swift` (module-level `appState`, `commands`, `sendEvent`,
  `sendEventAsync`). Depends on `HackerNews`.

The migration away from a hand-written `swift-java jextract` bridge is
documented in [`docs/skip-fuse-adoption.md`](docs/skip-fuse-adoption.md).
The previous architecture is in [`docs/historical/`](docs/historical/).

## Goals

- One Swift type (the `AppCore` workhorse class in `HackerNewsReader`)
  drives both platforms; one `AppEvent` enum carries every user-driven
  mutation.
- iOS: direct `@Observable` + SwiftUI; no bridge in the iOS path.
  `RootView` reads the module-level `appState` and `commands` from
  `HackerNewsReader` directly. Descendants take `AppState` (the
  `@Observable final class`) as a parameter and call the bridged
  `sendEvent(_:)` / `sendEventAsync(_:)` free functions.
- Android: bridged via SkipFuse. The Compose UI reads `appState`
  directly — the bridging plugin emits a Kotlin `class AppState` whose
  property getters JNI-call into the Swift `@Observable`'s
  ObservationRegistrar, which SkipFuse routes through Compose's
  `MutableStateBacking` so reads register with the snapshot system and
  mutations recompose. Events go back through the bridged
  `sendEvent` / `sendEventAsync` package-scope functions.
- Networking lives in the `HackerNews` target. `Client` is a `Sendable`
  struct with two `@Sendable` closure properties (`frontPage`,
  `search`). Tests inject closures directly. Production callers use
  `Client()` which wires the live `URLSession` HTTP path. `frontPage`
  hits the Firebase API; `search` hits Algolia.
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

### Module split

- **`HackerNews` is a thin SDK target.** Just `Client + Story + Page`
  and the private Firebase / Algolia decoders. No app-level state, no
  loading lifecycle. Reusable in isolation; the test target
  `HackerNewsTests` exercises it without touching the reader.
- **`HackerNewsReader` owns the reducer and presentation lifecycle.**
  `AppCore` (workhorse `actor`), `Core.swift` (the bridged module
  surface — `appState`, `commands`, `sendEvent`, `sendEventAsync`),
  `AppState` (`@Observable`), `StoryRow` (UI row = `Story + isRead`),
  and `LoadableStories` / `LoadStatus` (pagination + UI lifecycle).
  The pagination logic stays here on purpose — `LoadStatus.error:
  String` is presentation-shape, and the cursor (`LoadedStories`) is
  only meaningful alongside it. `HackerNewsReader` is the only public
  product in `Package.swift`; iOS and Android consume one product.

### Bridge

- **Adding a new `@Observable` property: add the field on `AppState`.**
  The class already carries `// SKIP @bridgeMembers`, so every new
  public member bridges automatically — no per-field marker, no thunk,
  no Kotlin holder, no `*OnChange` SAM. The Android side picks the
  change up on the next `./gradlew :app:assembleDebug` (or Android
  Studio Run): the `skipExport` task in `android-app/app/build.gradle.kts`
  is wired into `preBuild` and re-runs `skip export` when Swift sources
  or `Package.swift` change. The export transitively produces both
  `HackerNewsReader-debug.aar` and `HackerNews-debug.aar`.
- **`// SKIP @bridgeMembers` (type-level) vs `// SKIP @bridge`
  (per-member).** Bridged structs/classes here use `@bridgeMembers`,
  which bridges every public member of the type with one annotation.
  Reach for per-member `// SKIP @bridge` only when bridging a strict
  subset. Use `// SKIP @nobridge` on a single member to opt it out
  (e.g. `StoryRow.init(story:isRead:)`, kept `@nobridge` because rows
  are constructed Swift-side from `AppState`'s projections).
  **`// SKIP @bridge` at the type level alone is not the same** —
  that produces a Kotlin class with no field accessors (only
  `Identifiable.id` as `ObjectIdentifier`). Always use `@bridgeMembers`
  for whole-type bridging.
- **`AppCore.init()` is the bridged init.** The `init(client:clock:)`
  is a test seam — its parameter types (`Client` closure-bag,
  `any Clock<Duration>` existential) don't bridge, and it's
  unmarked.
- **`AppCore` (workhorse actor) is intentionally not bridged.**
  It's internal coordination — `sendEvent`, `scheduleSearchFetch`,
  `makeFetchTask`, the listener Task spawned from init. The bridged
  surface lives at module scope in `Core.swift`: `appState`,
  `commands`, `sendEvent`, and `sendEventAsync`.

### iOS view layer

(Enforced by `ios-app/HackerNewsReader/RootView.swift`.)

- Views accept `AppState` (the `@Observable final class`) as a
  parameter; they never own the core itself. The root view passes
  `appState` (imported from `HackerNewsReader`) into the tree.
- Events flow back by calling `sendEvent(_:)` (sync, fire-and-forget)
  or `await sendEventAsync(_:)` (awaitable, for `.refreshable`)
  directly — both are module-level functions on the
  `HackerNewsReader` import, no `@Environment` plumbing.
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

### Networking

- **`Client.frontPage` uses the official Firebase HN API**
  (`hacker-news.firebaseio.com/v0`). One request for
  `topstories.json` (up to 500 IDs in front-page order), then up to
  50 parallel `item/{id}.json` fetches in a `withThrowingTaskGroup`.
  The Algolia API does not expose HN's live ranking, so Firebase is
  the only transport that matches `news.ycombinator.com`. Per-item
  fetch failures are dropped (page returns `count - failed` stories)
  rather than failing the whole page — mirrors the Algolia path's
  tolerance for hits missing required fields.
- **`Client.search` stays on Algolia** (`hn.algolia.com/api/v1`).
  Firebase has no text-search endpoint. Both transports decode into
  the same `Story` shape.
- **Order preservation is load-bearing.** `withThrowingTaskGroup`
  yields children in completion order, not submission order. Each
  child returns `(orderIndex, Story?)`; the result is sorted by index
  before `compactMap` flattens to `[Story]`.

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
  resumption, fetch / commit Tasks spawned by `sendEvent`,
  post-`clock.sleep` continuations) deterministically. Replaces
  `Task.megaYield()`,
  which was probabilistic. Caveat: the queue is strict FIFO, while
  real actors honour task priority — fine because test code has no
  `Task(priority: …)` diversity.
- **`try` (not `try?`) on the debounce `clock.sleep`.** The fetch
  Task body uses `try await clock.sleep(for: debounce)` and lets the
  throw propagate. Swallowing it would let cancelled tasks fall
  through to the client's fetch call.
- **Batch into one `core.run` per test.** `TestCore.run` follows the
  Point-Free `Actor.run` pattern (Video #362) — its purpose is to
  group multiple reads and `sendEvent` calls into a single isolation
  hop with a consistent snapshot. Default to one `core.run { core in
  … }` block per test; only split when a real suspension boundary
  forces it (`await core.settle()`, `await clock.advance(by:)`,
  `await someTask.value`, `await iterator.next()`). `sendEvent`
  returns with state already mutated, so adjacent reads inside the
  same block see the new state.
- **Park mocks with `clock.sleep(for: .seconds(Int.max))`.** Mocks
  that must hang until the parent Task cancels them call `try await
  clock.sleep(for: .seconds(Int.max))` on the injected `TestClock`.
  The test never advances that clock, so the sleep is unbounded in
  test time with no real-time fallback. Gotcha: `Duration.seconds(.
  infinity)` and `.seconds(.greatestFiniteMagnitude)` compile but
  trap at runtime (Double→Int128 conversion); `.seconds(Int.max)`
  is the working "as large as Duration allows" spelling (~292
  billion years).
- **Networking on Android requires `import FoundationNetworking`**
  inside `#if canImport(FoundationNetworking)`. Without the
  conditional import, the cross-compile fails on `URLSession`.
- **`Client(fetch:)` is the URL-construction test seam.** Tests
  inject a `@Sendable (URLRequest) async throws -> (Data, URLResponse)`
  closure and capture the request directly — no `URLProtocol`, no
  global mutable state, no `.serialized` suite, and tests run in full
  parallel. The Firebase tests dispatch on URL path (`topstories.json`
  vs `item/{id}.json`) inside the injected fetch.

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
- **Architecture: module-level globals + `AppCore` workhorse actor.**
  `Core.swift` declares `@MainActor public let appState`, `commands`,
  and the `sendEvent` / `sendEventAsync` free functions — Swift's
  thread-safe one-time init guarantees a single instance per process.
  `AppCore` is an `actor` whose `unownedExecutor` borrows MainActor's
  (SE-0392), so it stays in MainActor's isolation region; the
  non-Sendable `AppState` reaches the actor via one transient
  `nonisolated(unsafe)` rebind at construction (SE-0414 region
  isolation makes this sound). The long-lived `searchQuery` listener
  Task is spawned from `AppCore`'s sync init body — Task.init's
  `@_inheritActorContext` keeps the body in the actor's isolation
  region.
- **`sendEvent` is the single orchestration entry.** All four
  fetch flows (feed refresh / feed load-more / search refresh /
  search load-more) plus `toggleRead` / `openStory` live inline as
  switch arms in `AppCore.sendEvent(_:)`. The intentional duplication
  is the point — each arm reads top-to-bottom for its event with
  no helper jumps. The one method that survives outside `sendEvent`
  is `scheduleSearchFetch`, kept private because the listener Task
  invokes it on every keystroke.
- **Tests substitute `TestCore` (per-instance `actor`).**
  Different `TestCore`s run on different executors so tests
  parallelise. `TestCore.run { ... }` is the Point-Free actor-run
  hop for grouped snapshot reads. `TestCore` carries an `isolated
  deinit` (SE-0371, Swift 6.2) that calls `appCore.shutdown()` —
  this breaks the `TaskRegistry → listener-Task → self` cycle when
  each test releases. (Requires macOS 15.4 floor for SE-0371;
  iOS floor stays at 17 because the production `appCore` is
  app-lifetime and never deinits.)

## Build & test

```sh
# HackerNewsReader + HackerNews unit tests (macOS host).
cd HackerNewsReader && \
  JAVA_HOME=/Applications/Android\ Studio.app/Contents/jbr/Contents/Home \
  swift test --disable-sandbox

# iOS app build.
cd ios-app && \
  xcodebuild -project HackerNewsReader.xcodeproj \
    -scheme HackerNewsReader \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation build

# Android: assemble the APK. The `skipExport` Gradle task re-runs
# `skip export` automatically when Swift sources change and is a no-op
# otherwise; one invocation transitively produces both
# HackerNewsReader-debug.aar and HackerNews-debug.aar in skip-libs/.
cd android-app && \
  JAVA_HOME=/Applications/Android\ Studio.app/Contents/jbr/Contents/Home \
  ./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.example.hackernewsreader/.ui.MainActivity
```

The iOS `.xcodeproj` is generated from `ios-app/project.yml` via
`xcodegen` and gitignored. The Android `skip-libs/` directory is also
gitignored — it's a build artefact.
