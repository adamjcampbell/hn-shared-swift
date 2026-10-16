# Agent rules

Context, architecture, and the consumption story live in
[`README.md`](README.md). This file is the rules.

## Architectural decisions

[`docs/adr/`](docs/adr/README.md) is the durable record of every
architectural choice in this project. Before proposing a change that
affects state shape, concurrency, the bridge surface, or the boundary
between platforms, read the relevant ADRs in
[`docs/adr/README.md`](docs/adr/README.md). If you make a new
architectural decision, add a new ADR — copy an existing one as a
template, give it the next number, and link it from the index.
Existing ADRs are immutable; if a decision changes, write a new one
that supersedes the old.

## Build & test

```sh
# Swift unit tests (macOS host).
cd HackerNewsReader && swift test

# Generator contract, from repository root after building the pinned tool.
# Requires JDK and cached Kotlin 2.2.21 compiler jars or kotlinc + that stdlib.
python3 scripts/test-generate-android.py

# iOS app.
cd ios-app && \
  xcodebuild -project HackerNewsReader.xcodeproj \
    -scheme HackerNewsReader \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation build

# Android (macOS host). `preBuild` depends on `buildSwift`, which runs
# runtime/build.py when its declared inputs change.
cd android-app && \
  JAVA_HOME=/Applications/Android\ Studio.app/Contents/jbr/Contents/Home \
  ./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.example.hackernewsreader/.ui.MainActivity
```

The iOS `.xcodeproj` is generated from `ios-app/project.yml` via `xcodegen`
and gitignored. Android generated peers, jars and native libraries live in
the gitignored `android-app/build/swift/`. The current script requires
Swift/Android SDK 6.3.1 and NDK 27.3.13750724; see the Android README.

## Module split

- `HackerNews` is a thin SDK: `Client` + `Story` + `Page` + private
  Firebase / Algolia decoders. No app state, no loading lifecycle.
- `PlatformSupport` owns HTTP transport, preferred languages and native
  time formatting, not app state. Android uses FoundationEssentials + JNI;
  Apple platforms use Foundation.
- `HackerNewsReader` owns the presentation lifecycle: `Model`, `Core`,
  `SendMessageAction`, `Message`, `Command`, plus `StoryRow`,
  `LoadStatus`, `LoadedStories`, and the free functions that build and
  mutate the core (`makeCore` / `makeAppCore`, `apply`, `applySearchQuery`).
- `apply`, `applySearchQuery` and `applyCancellation` own core writes to
  `Model`. Don't add mutators on `Model`.
- `Message` is UI → core; `Command` is core → UI. Don't name a new type
  `Effect` — reserved for a possible future TCA-style reducer.
- Drop type prefixes in namespaced modules: `HackerNews.Story`, not
  `HackerNews.HNStory`. Rename consumer-side collisions (`Story` →
  `StoryRow`) rather than reinstating the prefix.
- Presentation strings live precomputed on `StoryRow`, not in the
  view. Don't read `Date.now` inside view bodies — projections on
  `Model` capture `Dependencies.current.date.now` once per access so both
  platforms render the same caption for the same input. See
  [ADR-0017](docs/adr/0017-presenter-rows-in-model.md).

## Bridge (official Swift–Java)

- Keep swift-java pinned to `301e3da710ede7af93e798f1ce1c7950715a5748`
  and JNI core locked to `b440a0be98381550cf189c903782e817619ffa05`.
  No Skip dependencies, CLI, patches, old SwiftJNI, or kotlin-reflect are needed.
- `scripts/generate-android.swift` uses SwiftParser to discover public
  `Model` fields and generate checked MainActor accessors, per-property
  Observation invalidation subscriptions, and value projections. Do not
  hand-edit `AndroidReader.generated.swift` or generated Kotlin `Model.kt`.
  Properties require explicit types; unsupported bridge types fail generation.
  Writable fields support String/Int/Int64/Bool/Double. Read-only fields also
  support Date, String?, [String] and the three value projections as plain,
  optional or array values. See ADR-0022 before extending the type boundary.
- App, Observation, and core code remain Swift 6. Only generated synchronous
  JNI thunks compile in Swift 5 mode. Copy `Message` into Swift before any
  suspension; do not add a raw-peer async future path.
- Kotlin `suspendCancellableCoroutine` cancels native task handles, which
  propagate cancellation through Swift to the underlying fetch.
- Commands use official typed Java peers and a Kotlin Flow adapter. The
  native pump survives Activity recollection until `Core.close()`; cancelling
  a collector removes its subscription, not the pump. Only one consumer is supported.
- Close subscriptions, tasks, native peers and arenas explicitly. Production
  `Core` has Application lifetime, not Activity lifetime.
- The UI Looper bootstrap still uses private libdispatch SPI pinned to Swift
  Android SDK 6.3.1. Keep MainActor checks; do not substitute another UI actor.
  Upgrades require device tests. See [ADR-0022](docs/adr/0022-official-swift-java-bridge.md).

## iOS view layer

- Read state via `@Environment(Model.self)`. Dispatch via
  `@Environment(\.sendMessage)` — `sendMessage(.foo)` fire-and-forget,
  `await sendMessage.run(.foo)` for `.refreshable` / one-shot `.task`.
- Don't write `private var foo: some View`. Extract into a
  `private struct Foo: View` — `some View` computed properties inline
  into the parent body and lose per-section skip behaviour.
- Don't construct `Binding(get:set:)`. Use `@Bindable var model = model`
  + `$model.foo`. Closure shims aren't `Hashable` and break SwiftUI's
  animation / transaction identity tracking.
- Two states of the same surface (empty/full, search/main): always
  render the underlying view and reveal the alternate via
  `.overlay { if cond { … } }`. Top-level `if/else` destroys the
  inactive branch's identity, scroll position, and animation hooks.
  `.background(.background)` occludes when the overlay must fully cover.
- Attach `.searchable`, `.navigationTitle`, etc. to the inner content
  view (the `List`), not to `NavigationStack`.
- Don't store closures as `View` struct properties — closures aren't
  `Equatable`, so the view is always reconstructed. Wrap in an
  `Equatable` capability struct and inject via `@Environment`, or pass
  the `@Observable` class itself. Inline closures in modifiers are fine.
- Always mount; control visibility via modifiers
  (`opacity`, `allowsHitTesting`). Cross-platform exception: Compose
  defaults to `if/else`; always-mount on Android only when layout
  stability demands it.

## Android / Compose

- Kotlin holds Compose revision counters and immutable value copies, not
  authoritative mutable app state. Getters read Swift's latest state; they
  are not snapshot-versioned reads tied to a Compose revision.
- Copy native values inside confined `SwiftArena` scopes and dispose them
  before leaving those scopes. Do not retain native value peers in the UI.
  `Date` projects to epoch-seconds `Double`.

## Networking

- `Client.frontPage` → Firebase (`hacker-news.firebaseio.com/v0`).
  Algolia does not expose live ranking; Firebase is the only transport
  that matches `news.ycombinator.com`.
- `Client.search` → Algolia (`hn.algolia.com/api/v1`). Firebase has no
  text-search endpoint.
- Order preservation in `withThrowingTaskGroup` is load-bearing.
  Children yield in completion order; each returns `(orderIndex,
  Story?)` and the result is sorted before `compactMap`.
- Drop per-item fetch failures (page returns `count - failed` stories)
  instead of failing the whole page. Mirrors Algolia's tolerance for
  hits missing required fields.
- `Client(fetch:)` is the URL-construction test seam. Inject a
  `@Sendable (URL) async throws -> HTTPResponse` closure (body and status)
  — no `URLProtocol`, no global mutable state, full parallel tests.
- PlatformSupport uses URLSession on Apple and OkHttp callbacks via JNI
  on Android. The seam is GET-only; JSON decoding stays shared. Swift
  cancellation cancels the Android Call and resumes with CancellationError.
  Do not reintroduce FoundationNetworking into the Android native closure.

## Strings & localization

- User-visible strings are catalog-backed. To add or change one,
  edit `Sources/HackerNewsReader/Resources/Localizable.xcstrings`
  and rerun `scripts/generate-strings.swift`. `Strings.swift` is
  generated; don't hand-edit.
- `localized(_:default:)` (in `Localization.swift`) is the only
  lookup helper. Don't introduce parallel platform-side string
  stores (no Android `strings.xml`, no per-platform `tr(...)`).
- Apple looks up the compiled bundle; Android selects generated catalog
  tables using PlatformSupport language preferences. Compose reads the
  bridged `Strings` enum. Preserve the shared single-pass formatter so
  inserted user text is never reinterpreted as format tokens. See
  [ADR-0021](docs/adr/0021-foundation-light-platform-services.md), which
  supersedes ADR-0018's Android resource lookup, not its single-catalog rule.

## Concurrency & testing

- `clock` / `client` / `date` are ambient via the `@TaskLocal`
  `Dependencies`, not injected into a type. Production reads the live
  defaults (`ContinuousClock()`, `Client()`, `Date()`); `withCore`
  defaults `clock` to `ImmediateClock()`. Reach for `TestClock` only
  when asserting on debounce timing, and pass the same clock to
  `commitSearch(_:core:clock:isolation:)`.
- `TestActor` installs a `DispatchSerialQueue` as `unownedExecutor`.
  `withCore` is isolated to a fresh `TestActor`, so `makeCore`'s
  `#isolation` binds there; the body receives that actor as its first
  parameter, no force-cast needed.
- `await waitUntil { core.model.<cond> }` is the default
  synchronisation: it re-arms `withObservationTracking` and waits on the
  real observable transition (a status flips, a `LoadedStories`
  populates or clears). `settle(_:)` drains the actor's queue twice for
  the few steps with no transition to wait on (a keystroke that leaves
  `Model` unchanged, a cancel-and-replace through parked sleeps); it is
  the last resort. `TestActor.runPending()` is the underlying single
  drain, used directly only where a drain is irreducible (e.g. parking a
  fetch on its `clock.sleep` before `advance`).
- Use `try` (not `try?`) on `clock.sleep` so cancellation propagates;
  swallowing it lets cancelled tasks fall through to the live fetch.
- No `core.run` batching: the `withCore` body is one isolated scope, so
  write reads and `await core.sendMessage(...)` flat. Split only across
  real suspension boundaries (`waitUntil` / `settle`, `clock.advance`,
  `Task.value`, `iterator.next`). Alias `let model = core.model` at the
  top.
- Park mocks with `try await clock.sleep(for: .seconds(Int.max))`.
  `.infinity` / `.greatestFiniteMagnitude` compile but trap (Double →
  Int128).
- Wrap test setup in `withCore { actor, core in … }`. It binds
  `Dependencies.$current.withValue(...)` and runs `makeCore` inside that
  binding, so the listener `Task` and every fetch inherit the pinned
  deps, then `core.cancelAll()`s on exit to break the
  `listener-Task → Model` cycle before the next test. Mocks pass through
  `client: .mock(frontPage: …, search: …)`.
- Pin time with `withCore(now:)`, or `Dependencies.$current.withValue`
  (copy and mutate `Dependencies.current` to override a subset), when
  asserting on `StoryRow.metaLine` / `feedHeaderSubtitle`. `withCore`
  opens the binding around `makeCore` and the body so listener tasks and
  projections share the same `now`.

## State shape

- `Model` is a flat `@Observable` mega-struct data bag. Add new state
  as a flat per-axis field. Don't introduce medium-sized wrapper types
  whose only job is to bundle two or three fields.
- A nested struct earns its keep when ≥ 2 of: operation repetition
  (Casey), temporal access coupling (Acton), Carmack-lightweight.
  `LoadStatus` and `LoadedStories` qualify. If a candidate doesn't,
  flatten its members onto `Model`.
- Avoid "State" in nested type names — `LoadStatus`, not
  `FeedLoadState`. Reserve "State" for the top-level concept.
- For one shared `[Entity]` split across multiple views, prefer one
  `[ID: Entity]` store plus per-view `[ID]` lists over parallel
  denormalised arrays.
- Trust the boundary dedupe (bridge / SwiftUI diffing). Don't sprinkle
  `if !state.x.contains(...)` whack-a-mole guards inside `apply` /
  `applySearchQuery`.

## Doc & comment style

- Default to no comments. Add one only when the *why* is non-obvious
  — a constraint, a workaround, a surprising invariant. One short line
  max; never multi-line blocks.
- `///` doc comments are library docs, not a journal. Cut history,
  SE-number prose, tuning-constant tables, Skip-limitation TODOs.
  `Parameters` / `Returns` / `Throws` are mandatory when applicable.
- Passive / declarative over "we" / "our" in durable docs. Solo
  author; collective pronouns mislead.
- Don't end paragraphs with aphoristic closers ("X pays off", "X earns
  its keep", "the platform pieces stay idiomatic"). Stop when the
  point is made.
