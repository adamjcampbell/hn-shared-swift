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

Names borrow from Elm — `Model`, `Message` in, `Command` out —
implemented in **idiomatic Swift, made concurrency-safe by an
`actor`**: a single `Engine` actor owns every write to `Model`, so
the `@Observable` class itself stays a plain mutable data bag while
race-free access is enforced by Swift 6's isolation system. `Effect`
is deliberately avoided as a name — reserved should we ever fold
`Engine` into a TCA-style reducer.

The Swift package splits into two targets:
- `HackerNews` — API client + entity types (`Client`, `Story`, `Page`).
- `HackerNewsReader` — `Model` + `Engine` + the bridged module
  surface. `makeCore()` returns a `Core` of (`model`, `commands`,
  `sendMessage`); `SendMessageAction` is the Equatable
  capability struct (mirroring SwiftUI's `DismissAction`) exposing
  `send(_:)` and `suspend run(_:)`. `Message` (UI → core) and
  `Command` (core → UI) form the symmetric Elm-style pair. Plus
  `StoryRow`, `LoadStatus`, `LoadedStories`. Depends on `HackerNews`.

The migration away from a hand-written `swift-java jextract` bridge is
documented in [`docs/skip-fuse-adoption.md`](docs/skip-fuse-adoption.md).
The previous architecture is in [`docs/historical/`](docs/historical/).

## Goals

- One Swift type (the `Engine` workhorse actor in
  `HackerNewsReader`) drives both platforms; one `Message` enum
  carries every user-driven mutation.
- iOS: direct `@Observable` + SwiftUI; no bridge in the iOS path.
  `HackerNewsReaderApp` holds the `Core` via `@State` and
  hands it to `RootView`, which installs the `Model` and the
  `\.sendMessage` capability into the SwiftUI environment.
  Descendants read state via `@Environment(Model.self)` and dispatch
  messages via `@Environment(\.sendMessage)` — `sendMessage(.foo)` for
  fire-and-forget, `await sendMessage.run(.foo)` for awaitable.
- Android: bridged via SkipFuse. `App.onCreate` calls `makeCore()`
  once and stashes the `Core` for the process lifetime;
  `MainActivity` reads it off the `Application` and passes it to
  `StoryScreen`. Compose reads `core.model` directly — the bridging
  plugin emits a Kotlin `class Model` whose property getters JNI-call
  into the Swift `@Observable`'s ObservationRegistrar, which SkipFuse
  routes through Compose's `MutableStateBacking`. Messages go back
  through `core.sendMessage.send(...)` / `core.sendMessage.run(...)`.
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
- **`HackerNewsReader` owns the presentation lifecycle.** `Engine`
  (workhorse `actor`, internal, in `Engine.swift`), with the bridged
  factory `makeCore()` returning the `Core` value in `Core.swift`;
  `SendMessageAction` (Equatable capability struct, `DismissAction`-
  flavoured, exposing `send(_:)` / `suspend run(_:)`); `Model`
  (`@Observable` flat mega-struct bag); `StoryRow` (UI row = `Story
  + isRead`); and the two surviving small value types `LoadStatus`
  + `LoadedStories`. `Model` carries six flat per-axis fields
  (`feedLoaded`/`feedInitialStatus`/`feedLoadMoreStatus` and the
  search mirror) — the former `LoadableStories` wrapper was dissolved
  because it was a medium-sized helper with three different reader
  cadences and no operations of its own. `LoadStatus` and
  `LoadedStories` earn their keep (operation repetition + temporal
  access coupling + Carmack-lightweight). Mutators live on `Engine`,
  not on `Model`. `HackerNewsReader` is the only public product in
  `Package.swift`; iOS and Android consume one product.
- **`Message` (UI → core) and `Command` (core → UI) map to Elm's
  `Msg` / `Cmd`.** Inputs in, one-shot side-effects out — the
  symmetric pair around the `Engine`. The word "Effect" is
  intentionally avoided so it stays free should we adopt a TCA-style
  reducer; `LaunchedEffect` / `SideEffect` also have separate
  meanings in Compose. Commands are one-shot imperative messages
  with no return value.

### Bridge

- **Adding a new `@Observable` property: add the field on `Model`.**
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
  are constructed Swift-side from `Model`'s projections).
  **`// SKIP @bridge` at the type level alone is not the same** —
  that produces a Kotlin class with no field accessors (only
  `Identifiable.id` as `ObjectIdentifier`). Always use `@bridgeMembers`
  for whole-type bridging.
- **`Engine` (workhorse actor) is intentionally not bridged and
  internal.** It's internal coordination — `sendMessage`, the private
  `fetch` helper, the listener Task spawned from init with the
  debounced search-fetch flow inlined into its loop. The bridged
  surface lives on `Core` (model + commands + sendMessage capability)
  returned from `makeCore()`, with `SendMessageAction` holding the
  only out-of-module reference to the `Engine`.

### iOS view layer

(Enforced by `ios-app/HackerNewsReader/RootView.swift`.)

- Views read `Model` (the `@Observable final class`) via
  `@Environment(Model.self)`; `RootView` installs it from the
  `Core` owned by `HackerNewsReaderApp`.
- Messages flow back through `@Environment(\.sendMessage)`, a
  `SendMessageAction` capability installed alongside the state.
  `sendMessage(.foo)` is fire-and-forget (SwiftUI `DismissAction`-style
  `callAsFunction`); `await sendMessage.run(.foo)` is awaitable
  (`.refreshable`, one-shot `.task`). The wrapper is `Equatable` via
  `===` on its held `Engine?` — without it, raw closures in
  `EnvironmentValues` would defeat SwiftUI's environment diff and
  invalidate every descendant on each parent body re-eval.
- Don't write `private var foo: some View` on a View. SwiftUI can't
  diff computed properties — they inline into the parent body and
  lose per-section skip behaviour. Extract into a private
  `struct Foo: View`.
- For two-way bindings to `@Observable` properties, use `@Bindable`
  + `$model.foo`. **Never** construct a `Binding(get:set:)` closure
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

- **Inject `clock: any Clock<Duration>` into `Engine` for tests.**
  Production wires `ContinuousClock()` via `makeCore()`; tests
  default to `ImmediateClock()` (in `withEngine`) and override
  with a `TestClock` only when asserting on debounce timing. The
  private `fetch` helper uses `clock.sleep(for:)` for the search
  debounce. Tests pass a `TestClock` (from
  `pointfreeco/swift-clocks`) and call `clock.advance(by:)` to
  release suspended sleepers atomically. The private
  `commitSearch(_:on:)` helper in `CoreTests` packages the
  listener-debounce-runPending pattern (`searchQuery = X` →
  `runPending` → advance → `runPending`) for tests that only care
  about the post-commit state.
- **`TestActor` installs a `DispatchSerialQueue` as `unownedExecutor`.**
  SE-0392 + Point-Free Video #362 pattern. `TestActor` is the
  per-test isolation provider; the `withEngine(...)` fixture
  passes it as `isolation:` when constructing `Engine`, so the
  engine borrows TestActor's executor directly (no sibling executor
  actor needed). The `nonisolated func runPending() async` enqueues
  a continuation-resume at the back of the queue, so awaiting it
  drains every pending job (listener-Task resumption, fetch /
  commit Tasks spawned by `sendMessage`, post-`clock.sleep`
  continuations) deterministically. Replaces `Task.megaYield()`,
  which was probabilistic. Tests recover the TestActor as
  `engine.testActor` via a test-target extension that force-casts
  `engine.isolation` (relaxed to module-internal). Caveat: the
  queue is strict FIFO, while real actors honour task priority —
  fine because test code has no `Task(priority: …)` diversity.
- **`try` (not `try?`) on the debounce `clock.sleep`.** The fetch
  Task body uses `try await clock.sleep(for: debounce)` and lets the
  throw propagate. Swallowing it would let cancelled tasks fall
  through to the client's fetch call.
- **Batch into one `engine.run` per test.** `Engine.run` follows
  the Point-Free `Actor.run` pattern (Video #362) — its purpose is
  to group multiple reads and `sendMessage` calls into a single
  isolation hop with a consistent snapshot. Default to one
  `engine.run { engine in … }` block per test; only split when a
  real suspension boundary forces it (`await engine.testActor.runPending()`,
  `await clock.advance(by:)`, `await someTask.value`,
  `await iterator.next()`). `sendMessage` returns with the model
  already mutated, so adjacent reads inside the same block see the
  new state. Inside the closure, alias `let model = engine.model` at
  the top — direct capture of the outer-scope `model` is rejected
  because the `run` body is `@Sendable`.
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
- **Architecture: `makeCore()` factory + `Engine` workhorse
  actor.** `Core.swift` declares `@MainActor public func makeCore()
  -> Core`, returning a struct of (`model`, `commands`,
  `sendMessage`). Hosts call it once at app scope (iOS: `@State` on
  `App`; Android: `Application.onCreate`) and hold the `Core` for
  the process lifetime — the `Engine` lives as long as the
  `SendMessageAction` inside the `Core` holds it. `Engine` (in
  `Engine.swift`) is an `actor` whose `unownedExecutor` borrows
  MainActor's (SE-0392), so it stays in MainActor's isolation
  region; non-Sendable `Model` flows in via SE-0414 region isolation
  (the fresh `Model()` value is unaliased) and back out to the
  `Core` through a one-shot `@unchecked Sendable` box scoped to
  `makeCore`. Long-running listener Tasks are bootstrapped
  externally by `bind()` — `makeCore` reaches it synchronously via
  `engine.assumeIsolated { $0.bind() }` (a runtime no-op given the
  borrowed executor); tests `await engine.bind()` through the actor
  hop. Keeping the bootstrap out of `init` sidesteps the "Task
  spawned in a sync init body doesn't inherit actor isolation"
  workaround.
- **`sendMessage` is the single orchestration entry.** All four
  fetch flows (feed refresh / feed load-more / search refresh /
  search load-more) plus `toggleRead` / `openStory` live inline as
  switch arms in `Engine.sendMessage(_:)`. The intentional
  duplication is the point — each arm reads top-to-bottom for its
  message with no helper jumps. The debounced search-fetch flow
  triggered by every keystroke is similarly inlined into the
  listener Task's `for await` loop in `bind()`. `fetch(debounce:body:)`
  is the one shared helper — five callers (the listener + four
  `sendMessage` arms) use it for the cancellation-aware fetch
  (optional pre-sleep, post-sleep `Task.checkCancellation()`, and
  `URLError(.cancelled)` → `CancellationError` normalisation). Each
  caller wraps the await in its own `Task` for cancellation;
  `fetch` itself just returns `Page`.
- **Tests wrap setup in `withEngine { engine in … }`.** The
  helper builds a fresh `TestActor`, constructs `Engine` with it
  as `isolation:`, runs the body, and awaits `engine.cancelAll()`
  on exit (the body's outcome is captured as a `Result` so the
  teardown runs on a single path before rethrowing via `.get()` —
  `defer` can't `await`) — this breaks the
  `TaskRegistry → listener-Task → Engine` cycle deterministically
  before the next test starts. Mocks pass through `client:`
  (e.g. `client: .mock(frontPage: ..., search: ...)`), the optional
  `clock:` accepts a `TestClock`, and `now:` accepts a `@Sendable
  () -> Date`. Different TestActors run on different queues so
  tests parallelise across instances. The `engine.testActor`
  extension recovers the TestActor for `runPending()`.

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
