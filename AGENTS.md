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
  mutate the core (`makeCore` / `makeAppCore`, `apply`, `applySearchQuery`).
- `apply` and `applySearchQuery` are the only writers of `Model`. Don't
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
