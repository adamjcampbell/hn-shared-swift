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

# iOS app.
cd ios-app && \
  xcodebuild -project HackerNewsReader.xcodeproj \
    -scheme HackerNewsReader \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation build

# Android. The `skipExport` Gradle task re-runs `skip export` when Swift
# sources change and is a no-op otherwise.
cd android-app && \
  JAVA_HOME=/Applications/Android\ Studio.app/Contents/jbr/Contents/Home \
  ./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.example.hackernewsreader/.ui.MainActivity
```

The iOS `.xcodeproj` is generated from `ios-app/project.yml` via `xcodegen`
and gitignored. `skip-libs/` under `android-app/` is also gitignored.

## Module split

- `HackerNews` is a thin SDK: `Client` + `Story` + `Page` + private
  Firebase / Algolia decoders. No app state, no loading lifecycle.
- `HackerNewsReader` owns the presentation lifecycle: `Model`, `Core`,
  `SendMessageAction`, `Message`, `Command`, plus `StoryRow`,
  `LoadStatus`, `LoadedStories`, and the free functions that build and
  mutate the core (`makeCore` / `makeAppCore`, `apply`, `applySearch`,
  `runSearch`).
- `apply` and `applySearch` are the only writers of `Model`. Don't
  add mutators on `Model`.
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

## Bridge (SkipFuse)

- Adding an `@Observable` property: add the field on `Model`. `// SKIP
  @bridgeMembers` (already on the class) bridges every public member —
  no per-field marker, no Kotlin holder.
- Use `// SKIP @bridgeMembers` (type-level) for whole-type bridging.
  `// SKIP @bridge` at the type level alone drops field accessors —
  don't reach for it. Use `// SKIP @nobridge` for per-member opt-out.
- `Core.sendMessage` and `cancelAll` are intentionally `internal` and
  `// SKIP @nobridge`. The bridged Kotlin surface is the `Core` returned
  from `makeAppCore()`: its `model` and `commands`.
- `AsyncStream<T>` → `Flow<T>` via `.kotlin()` on the Kotlin side.
- Kotlin toolchain must match SkipFuse's exported AAR metadata
  (currently 2.3.0). `kotlin-reflect` is required at runtime.
- `suspend fun` uses `suspendCoroutine`, not
  `suspendCancellableCoroutine` — Kotlin cancellation does not
  propagate to the Swift Task.
- SkipFuse adoption rationale and gotchas:
  [ADR-0013](docs/adr/0013-skipfuse-bridgemembers.md).

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

- Bridged primitives become `MutableState` via `BridgedSource` +
  `MutableStateAdapter` (e.g. `model::searchQuery`.asMutableState).
  Local `set` must update `current` and notify listeners synchronously
  — the bridge dedup absorbs the echo.
- `BridgedSource`, `asMutableState`, `readThrough`, and the
  `appcoreGet*` accessors are intentional public API even when only
  one consumer exists today. Don't propose deleting as unused.

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
  `@Sendable (URLRequest) async throws -> (Data, URLResponse)` closure
  — no `URLProtocol`, no global mutable state, full parallel tests.
- Wrap `URLSession` in `#if canImport(FoundationNetworking)` +
  `import FoundationNetworking` for the Android cross-compile.

## Strings & localization

- User-visible strings are catalog-backed. To add or change one,
  edit `Sources/HackerNewsReader/Resources/Localizable.xcstrings`
  and rerun `scripts/generate-strings.swift`. `Strings.swift` is
  generated; don't hand-edit.
- `localized(_:default:)` (in `Localization.swift`) is the only
  lookup helper. Don't introduce parallel platform-side string
  stores (no Android `strings.xml`, no per-platform `tr(...)`).
- Skip-foundation gaps with `String(localized:bundle:)`,
  `LocalizationValue`, and `Bundle.module` at argument position are
  the reason for the indirection — Compose reads the bridged
  `Strings` enum across SkipFuse. See
  [ADR-0018](docs/adr/0018-localized-strings-catalog-generator.md).

## Concurrency & testing

- Targets **Swift 6.4+** (Xcode 27+). The core spawns work isolated to an
  actor *instance*, whose continuations must resume on that instance after
  `await` — broken in 6.3.0/6.3.1
  ([swiftlang/swift#88993](https://github.com/swiftlang/swift/issues/88993),
  fixed in 6.4 / 6.3.2+). ADR-0024 records the workaround stack that
  carried the design on 6.3; don't reintroduce it on a fixed toolchain.
- Fetches go through `Latest<Page>`, a host-confined latest-wins slot —
  one per list: `feed` (refresh + feed load-more) and `search` (the reload
  + search load-more). A refresh / new query cancels its list's in-flight
  load-more intrinsically through the shared slot. `apply` is `async` and
  caller-following — it `await`s the fetch and commits the `Model` in place
  — and `Latest` is latest-wins *at delivery* (a superseded caller throws
  `CancellationError` even if its work completed), so callers commit
  unconditionally (ADR-0026).
- Search is binding-driven and shaped like an `apply` arm: the reload is
  `applySearch(query:to:search:)` (`await load` over the `search` slot),
  and `runSearch` is a thin driver that `spawn`s one `applySearch` per
  `model.searchQuery` change. Latest-wins across keystrokes rests on
  SE-0431 (the per-query tasks claim the slot in creation order, in their
  synchronous head), not a held handle — the same ordering `feed` relies
  on. Don't insert an `await` before the slot claim or make the spawned
  closure non-host-isolated; that voids the order guarantee.
- `makeCore` is nonisolated and takes a `spawn` parameter — the
  isolation-carrying spawner used *only* where work must run *and* mutate
  the `Model`: the search driver (`runSearch`) and each `applySearch` it
  spawns. `makeAppCore` (`@MainActor`) injects
  `{ work in Task { await work() } }` (the `Task` inherits `MainActor` —
  global actor, no annotation or capture); `withCore` injects
  `{ work in Task { _ = isolation; await work() } }` (dynamic per-test
  `TestActor` capture). The `_ = isolation` spelling is a test-only
  concern; production is plain global-actor `Task`. The awaited `Latest`
  fetches need no spawner — they broker only `Sendable` values.
- `searchDebounce` / `client` / `date` are ambient via the `@TaskLocal`
  `Dependencies`, not injected into a type. Production reads the live
  defaults (250 ms, `Client()`, `Date()`); `withCore` defaults
  `debounce` to `.zero` so a search runs straight through to commit.
  There is no clock dependency and no `TestClock`: tests control time
  by controlling the *amount* — pass `debounceNeverElapses` to hold the
  debounce window open and assert mid-window behaviour (the parked
  sleep releases via cancellation on fixture exit).
- `TestActor` is a plain `actor` (default per-instance executor).
  `withCore` is isolated to a fresh `TestActor`, so `makeCore`, the
  spawner built there, and the body all run on it; the body receives
  that actor as its first parameter, no force-cast needed.
- `await waitUntil { <cond> }` is the default synchronisation: it
  re-arms `withObservationTracking` and waits on a real observable
  `Model` transition — a status flips, a `LoadedStories` populates or
  clears, `searchResults` change. There is no registry to observe; wait
  on the effect in the `Model`, or `await` the `apply` directly for
  `.refresh` / `.loadMore`. There is no `settle` and no `runPending`;
  nothing drains queues by count.
- To interrupt a fetch mid-call, park the mock on a `Gate`: the mock
  `await`s `gate.arrive()` (signals, then parks), the test `await`s
  `gate.arrival()` to know the fetch is inside the client, then
  triggers the interruption. The park releases on cancellation; check
  `Task.isCancelled` / `Task.checkCancellation()` after `arrive()`
  to surface it the way the transport would. `Hold` is the
  cancellation-*ignoring* variant — it releases only on `release()`,
  modelling a fetch whose round-trip completes *after* it was cancelled
  (cancel losing the race), to test the `Latest` delivery guard.
- No `core.run` batching: the `withCore` body is one isolated scope, so
  write reads and `await core.sendMessage(...)` flat. Split only across
  real suspension boundaries (`waitUntil`, `gate.arrival`,
  `Task.value`, `iterator.next`). Alias `let model = core.model` at
  the top.
- Wrap test setup in `withCore { actor, core in … }`. It binds
  `Dependencies.$current.withValue(...)` and runs `makeCore` inside that
  binding, so the search driver `Task` and every fetch inherit the
  pinned deps, then `core.cancelAll()`s on exit to break the
  `driver-Task → Model` cycle before the next test. Mocks pass through
  `client: .mock(frontPage: …, search: …)`.
- Pin time with `withCore(now:)`, or `Dependencies.$current.withValue`
  (copy and mutate `Dependencies.current` to override a subset), when
  asserting on `StoryRow.metaLine` / `feedHeaderSubtitle`. `withCore`
  opens the binding around `makeCore` and the body so the driver and
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
  `applySearch`.

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
