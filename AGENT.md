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
  `\.dispatch`. `AppState` itself is the `@Observable final class`;
  descendants take it as a parameter and rely on per-property tracking
  for invalidation. Events flow back through `\.dispatch` — the model
  is invisible below the root.
- Android: `JavaUIActor` global actor + a `Bridge` namespace composed
  from `AndroidSnapshot` / `AndroidCommands` / `AndroidBinding`
  primitives. `AndroidSnapshot` runs an `Observations` task → JSON
  snapshot → Java callback → Compose recomposition. Most mutations go
  through `appcoreDispatch(eventJSON:)`; `appcoreDispatchAwait(...)` is
  the awaitable variant for pull-to-refresh; `searchQuery` and
  `isLoading` ride per-property `AndroidBinding`s (the former is
  two-way for typing, the latter is one-way Swift→Kotlin driving the
  spinner + empty-overlay flicker guard).
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
- **Cold-start initial snapshot comes from `Observations` itself.**
  Per WWDC25 *What's new in Swift*, an `Observations` sequence emits
  the initial value as well as future ones. The bridge actor's
  `attach()` task therefore delivers a cold-start snapshot ~1–2 ms
  after `appcoreCreate` returns; Compose's `mutableStateOf<AppState?>`
  bridges that small `null` window. `BridgePerfTest.a_coldStart_…`
  is the regression guard.

## Non-obvious project rules

- **Never use `@unchecked Sendable` or `nonisolated(unsafe)` in
  `AppCore/Sources/`.** The architecture is built around proper isolation
  (actors, value types, single-instance singletons), and a hand-rolled
  unsafe escape hatch usually means the design is wrong. The single
  exception is `Sources/AppCoreAndroid/JavaInterop.swift`, which adopts
  `@unchecked Sendable` for the jextract-generated `Java*Sink` wrappers —
  swift-java does not yet mark `@JavaInterface` types as `Sendable`,
  but the underlying JNI handle is safe to share. If you add another
  exception, document the why in the same file.
- `AppCoreNative.swift`'s entry-point *signatures* are unconditional —
  jextract runs on the macOS host and silently skips functions sitting
  inside a `#if canImport(Android)` guard, so gating the signatures
  would empty out the generated Java module class. The function
  *bodies* are `#if canImport(Android)`-gated (no-ops on macOS); only
  the signatures need to compile cross-platform.
  `Bridge.swift`, `JavaUIActor.swift`, `LooperExecutor.swift`,
  `AndroidBinding.swift`, `AndroidSnapshot.swift`, and
  `AndroidCommands.swift` are wrapped end-to-end in
  `#if canImport(Android)` — they're internal, not jextract-scanned,
  and only referenced from the gated thunk bodies, so they don't need
  to exist on macOS at all. On the macOS host build `AppCoreAndroid`
  collapses to the public-API signatures + the cross-platform `*Sink`
  protocols (and `AndroidCompletion`).
- There is exactly one `AppModel` per process. `AppCoreNative` exposes
  the entry points (`appcoreCreate`, `appcoreDispatch`,
  `appcoreDispatchAwait`, `appcoreSetSearchQuery`,
  `appcoreGetSearchQuery`, `appcoreDestroy`) which all hop into the
  `@JavaUIActor`-isolated `Bridge` namespace via
  `JavaUIActor.assumeIsolated { Bridge.foo() }`. `Bridge.attach` is
  **once-and-only-once**: a `precondition` traps if it's called while
  already attached. The Kotlin side initialises `AppModelHolder` once
  from `AppCoreApplication.onCreate`; `BridgePerfTest` adds a
  `@Before { appcoreDestroy() }` so each test starts in a detached
  state and can pair `appcoreCreate(...)` with a `finally { appcoreDestroy() }`.
- `AppState` is an `@Observable final class` (originally a value-type
  `Snapshot` — renamed so the property reads as `appModel.state:
  AppState`). Don't rename it back to `State` — that collides with
  SwiftUI's `@State` property wrapper in iOS code.
- **`AndroidSnapshot` deduplicates emissions before the JNI hop.** The
  observation `Task` body encodes inside the `Observations` closure
  (`Observations { JNICoder.encode(source()) }`) and holds a local
  `var lastJSON: String?`, skipping `sink.deliver` when the new JSON is
  byte-identical to the prior one. `Observations` starts a transaction
  on every `willSet` regardless of value-equality, so without this
  guard a redundant write (e.g. setting `lastRefreshedAt` to its
  current value) would JNI-hop for nothing. Compose's
  `mutableStateOf<AppState?>` saves the recompose either way, but the
  wire round-trip costs ~100 µs per skipped emission. The dedup state
  lives inside the Task closure rather than on the primitive — `start()`
  cancels and respawns the Task, so a fresh sink gets a fresh
  comparison automatically.
- **Search-query writes are NOT events — they're per-property bridged.**
  Both platforms drive `state.searchQuery` directly: iOS via `@Bindable`
  + `$state.searchQuery`, Android via `BridgedSource` + the per-property
  JNI setter `appcoreSetSearchQuery` and getter `appcoreGetSearchQuery`.
  Swift is the single source of truth; the Kotlin `BridgedSource` keeps
  no local mirror — `current` reads through the JNI getter, `set`
  writes through the JNI setter (sync, via `Actor.assumeIsolated`),
  and `deliver` is the platform-push path for cold-start +
  programmatic Swift writes (Kotlin-originated writes don't fire it
  because of the bridge actor's `lastSetterValue` echo dedup;
  Compose's `TextFieldState` owns the typing buffer anyway).
  `AppEvent` retains only the command-shaped mutations (`toggleRead`,
  `openStory`, `refresh`).
  `AppModel.runSearchQueryWatcher` is an `async` method that iterates
  `state.observe(\.searchQuery).dropFirst()` and calls
  `runFetch(debounce: 250 ms)` on every willSet. `runFetch` keeps its
  cancel-and-replace `searchTask` and the `[client, clock, query]`
  capture — still load-bearing for sidestepping SE-0461's "unstructured
  Task captures non-Sendable self" hole.
- **`ObservedKeyPath<Root, Value>`** is the small `AsyncSequence`
  (`AppCore/Sources/AppCore/Observed.swift`) wrapping
  `withObservationTracking` for a single key path; modelled after
  Apple's `Observations` (SE-0475 / iOS 26+) but available on iOS 17+.
  Each `next()` re-arms by re-iterating, so the spec §13 fallback's
  recursion-from-`@Sendable onChange` isn't needed. The wait is
  `withCheckedContinuation` wrapped in `withTaskCancellationHandler`
  so the iterator exits cleanly when its surrounding task is cancelled
  even if no further `willSet` is coming. A `_ResumeOnce` coordinator
  (a small enum-state machine over an `OSAllocatedUnfairLock` on Apple
  / `Synchronization.Mutex` on Android) guarantees the
  `onChange`/`onCancel` race resumes the continuation exactly once. The iterator yields `Task.yield()` once after the
  suspension so the writer's `willSet` → assignment → `didSet` frame
  completes before reading the post-write value (Apple's `Observations`
  solves the same "willSet fires before mutation" problem by emitting
  at "transaction end"). Iterator is non-Sendable; iteration must stay
  in a single isolation domain (MainActor on iOS, the bridge actor on
  Android) — same constraint Apple's `Observations` has. Drop this
  type and use `Observations` directly when iOS 26 becomes the
  deployment floor.
- **The watcher loop body lives on AppModel; the Task lifetime lives on
  the host.** AppModel exposes `runSearchQueryWatcher() async` and
  hosts call `await appModel.runSearchQueryWatcher()` from inside their
  own Task. Spawning the Task *inside* AppModel —
  `Task { [self] in ... }` — captures non-Sendable `self` into a
  `sending` closure, which Swift 6.1 `[#SendingClosureRisksDataRace]`
  rejects. The async-method shape works because there's no `Task` /
  `async let` / `TaskGroup.addTask` creation in AppModel's body; the
  body runs on the caller's actor under SE-0461 and the `for await`
  iterator stays in that actor's region. Hosts (`MainActor` `.task` on
  iOS, the `@JavaUIActor`-isolated `Bridge.attach` on Android) own the
  cancellable Task. On Android the watcher Task is just
  `Task { await appModel.runSearchQueryWatcher() }` inline in
  `Bridge.attach` — no actor-method wrapper indirection (the previous
  `AndroidBridge`-actor architecture needed one to "re-enter" actor
  isolation; with `@JavaUIActor`-isolated `Bridge.attach`, the Task
  closure inherits the global-actor isolation directly).
- **Each host runs two `.task`-shaped Tasks side-by-side.** Folding
  them into one (TaskGroup or async let, inside AppModel or even on
  the host) was attempted and rejected by strict concurrency: AppModel
  is non-Sendable, so any `sending` closure that captures it (which is
  what `TaskGroup.addTask` / `async let` / `Task.init` produce) trips
  `[#SendingClosureRisksDataRace]`. The two-task shape is the
  Swift 6.3 idiom for non-Sendable hosts:
  - iOS `RootView`: two `.task` modifiers — one consumes
    `appModel.commands`, one awaits `appModel.runSearchQueryWatcher()`.
    SwiftUI manages each Task's lifetime per view
    appearance/disappearance.
  - Android `Bridge`: each composable primitive
    (`AndroidSnapshot`, `AndroidCommands`, `AndroidBinding`) owns its
    own `Task<Void, Never>?` field internally; `Bridge` itself owns
    only the `queryWatcherTask`. All are spawned in `Bridge.attach()`
    and cancelled in `Bridge.detach()`. Under `@JavaUIActor` global-
    actor isolation, Task closures inherit the same isolation, so
    capturing non-Sendable references stays in-region.
- **`JavaUIActor` runs on Android's main `Looper` (custom executor).**
  `JavaUIActor` is a global actor with a `nonisolated var unownedExecutor`
  pointing at `LooperExecutor.shared` (SE-0392 custom actor executors).
  `LooperExecutor` (`Sources/AppCoreAndroid/LooperExecutor.swift`) is a
  `SerialExecutor` whose `enqueue(_:)` JNI-calls
  `LooperPoster.postToMain(jobPointer)` (Kotlin object in
  `android-app/app/.../bridge/LooperPoster.kt`), which
  `Handler(Looper.getMainLooper()).post { … }`s back into Swift via
  the `Java_com_example_appcore_bridge_LooperPoster_runSwiftJob`
  `@_cdecl` (the only hand-written `@_cdecl` in the project; spec §2
  generally uses jextract). Net effect: every `@JavaUIActor`-isolated
  member — including sink callbacks fired from inside `Bridge.attach`'s
  pumps — runs on the UI thread. JNI thunks (always called from Compose
  on the UI thread) enter the actor's isolation domain synchronously
  via `JavaUIActor.assumeIsolated`, saving a `Task { await … }`
  allocation and the `AttachCurrentThread` cost on each sink delivery.
  `JavaUIActor.assumeIsolated` is hand-rolled
  (`withoutActuallyEscaping` + `unsafeBitCast`) because stdlib's
  `Actor.assumeIsolated` instance method gives the closure
  actor-instance isolation, not `@JavaUIActor` global-actor isolation;
  only `MainActor.assumeIsolated` is special-cased in stdlib to bridge
  the two. See the doc-comment on `JavaUIActor.swift` for the verified
  diagnostic.
  - **Sync thunk contract.** `appcoreCreate`, `appcoreSetSearchQuery`,
    `appcoreSetIsLoading`, and `appcoreDestroy` execute their actor
    work synchronously and only return after the mutation has taken
    effect. This tightens spec §9's old fire-and-forget contract;
    the JNI inbound mutation path is now strict-sync. The async
    snapshot *delivery* path (Observations → JSON → SnapshotSink) is
    still asynchronous.
  - **`appcoreDispatch` mirrors iOS's `AppEventDispatch` split.**
    `Bridge.dispatch(_:) async` is the awaitable form;
    `Bridge.enqueueDispatch(_:)` is sync, fire-and-forget (spawns an
    internal Task that awaits the async path). The fire-and-forget
    thunk (`appcoreDispatch`) uses `enqueueDispatch` so it can stay
    synchronous. The awaitable thunk (`appcoreDispatchAwait`) calls
    `Bridge.enqueueAwaitableDispatch(event, completion:)` which
    spawns a Task, awaits the async dispatch, and fires the
    `AndroidCompletion` so the Kotlin `awaitWithCompletion {}`
    helper resumes its `suspendCancellableCoroutine`. Pull-to-refresh
    in Compose is the primary consumer.
  - **Off-UI-thread JNI calls trap — this is intentional.** Compose
    dispatches all user events from the UI thread, and the bridge's
    executor *is* the UI thread, so `assumeIsolated` is sound. The
    contract is "JNI thunks may only be called from the UI thread";
    a background coroutine calling `AppCoreAndroid.appcoreDispatch(...)`
    will trap loudly inside `assumeIsolated`, which is the right
    failure mode (silent re-scheduling onto a different thread would
    hide a real bug). If a future use case genuinely needs an off-UI
    JNI caller, give that thunk a separate variant that wraps the
    actor call in `Task { await … }`; don't relax the
    `assumeIsolated` contract on the existing thunks.
  - **`LooperExecutor.checkIsolated()` is required.** Swift's runtime
    calls `SerialExecutor.checkIsolated()` from `Actor.assumeIsolated`
    (and other isolation-check sites) to verify the calling thread is
    the executor's expected thread. The default impl always traps with
    "Unexpected isolation context, expected to be executing on
    LooperExecutor", because Swift can't tell that Android's main
    `Looper` thread *is* this executor's domain. We override
    `checkIsolated()` to call `LooperPoster.isOnMainLooper()` via JNI
    (`Looper.myLooper() == Looper.getMainLooper()`). Don't remove this
    override — without it `appcoreCreate` traps at app launch.
  - **Android-only — no macOS fallback.** `LooperExecutor.swift`'s
    body is `#if canImport(Android)`-gated; `JavaUIActor.swift`,
    `Bridge.swift`, `AndroidBinding.swift`, `AndroidSnapshot.swift`,
    and `AndroidCommands.swift` are similarly gated; the JNI thunks
    in `AppCoreNative.swift` have `#if canImport(Android)`-gated
    bodies. On macOS, the entire bridge collapses to the public-API
    signatures + the cross-platform `*Sink` protocols + `AndroidCompletion`
    — jextract still scans these so the Java surface generates
    correctly. We don't need a fake macOS impl because `AppCoreTests`
    doesn't exercise the bridge primitives.
- **Echo dedup at the trust boundary.** `AndroidBinding<Root, Value>`
  runs an `Observations { root[keyPath: keyPath] }` loop whose
  emissions feed the deliver closure (which wraps a per-`Value` sink
  like `SearchQuerySink.deliverSearchQuery(value:)`). Without dedup,
  every Kotlin write would round-trip back through the sink and fire
  `BridgedSource.deliver` → Compose listener → recomposition, with no
  semantic effect (TextFieldState already has the value the user
  typed). The binding holds a `lastSetterValue: Value?` updated by
  `set(_:)`; the Observations loop skips emissions matching it. Same
  shape as the JSON-snapshot dedup (`lastJSON` in `AndroidSnapshot`)
  — dedup once at the trust boundary, not at every source.
- **Inject `clock: any Clock<Duration>` into `AppModel` for tests.**
  Default is `ContinuousClock()`. `runFetch`'s Task body uses
  `clock.sleep(for:)` for the debounce wait. Tests pass a `TestClock`
  (from `pointfreeco/swift-clocks`) and call `clock.advance(by:)` to
  release suspended sleepers atomically — no real-clock waiting. Two
  cancel-and-replace tests
  (`runFetch_coalescesRapidKeystrokes`,
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
- Adding a new mutation depends on its shape:
  - **Command-shaped** (toggle, refresh, navigate — fire-and-forget, no
    text input bound to a UI control): (a) new `case` on `AppEvent`
    (Swift), (b) `switch` arm in `AppModel.dispatch`, (c) matching
    `@SerialName`'d variant on Kotlin's `sealed class AppEvent` in
    `AppModelHolder.kt`. `Codable` is generated by MetaCodable's
    `@Codable` + `@CodedAt("type")` on the enum, so no per-case
    annotation is needed when the case name equals the wire string; add
    `@CodedAs("…")` per case only if they differ. No new JNI entry
    point.
  - **Per-property bridged** (continuously two-way bound to a UI
    control, like `searchQuery`): (a) make the `@Observable` property
    publicly settable on `AppState`; (b) drop it from `encode(to:)` so
    it doesn't ride the snapshot; (c) on Android, a new `XSink`
    Sendable protocol + entry in `appcoreCreate`'s parameter list,
    `appcoreSetX` and `appcoreGetX` JNI entry points, a new bridge
    actor field for `lastSetterValue`, a new `Observations { state.x }`
    task with the echo dedup; (d) on Kotlin, `BridgedSource<X>(readThrough = …, writeThrough = …)`
    constructed in `AppModelHolder` + a new sink override calling
    `bridgedSource.deliver`; (e) on iOS, just bind via `$state.x`. The host's existing `searchQuery` watcher loop
    automatically picks up new properties only if you wire them through
    `runFetch` or another shared trigger — usually each per-property
    primitive wants its own host-side reaction.
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
  toggling tests would mask a regression of `Observations`' initial-
  value emission by warming the executor.
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
    `AppState` (the `@Observable final class`) as a parameter; never
    `AppModel` itself. Per-property invalidation comes from `@Observable`
    tracking, not from prop-drilling individual fields.
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
    Foo: View` so the child gets its own diffing checkpoint. Pass
    `state: AppState` directly; the `@Observable` macro instruments
    each property read so SwiftUI re-runs the child body only when a
    property it actually reads is mutated. Leaf views that already
    take value-type slices (`Story`, `[Story]`) keep doing so —
    parameter equality is the right diff signal there.
  - For two-way bindings to `@Observable` properties (search text,
    toggles, slider values), use `@Bindable var state: AppState` plus
    `$state.foo` — Swift produces a writable-key-path Binding rooted
    on the observable. **Never** construct a `Binding(get:set:)`
    closure shim: closures aren't `Hashable` or
    reference-comparable, so the closure-shim form destroys the
    Hashable identity SwiftUI's animation/transaction tracking relies
    on, and the `Binding.init(get:set:transaction:)` overload doesn't
    fully salvage it (Point-Free episode #289). If a write needs
    side effects (debounce, network), express them at the model layer
    via observation, not inside a Binding setter.
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
