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

- One Swift type (`AppModel`) drives both platforms; one `AppEvent`
  enum carries every user-driven mutation.
- iOS: direct `@Observable` + SwiftUI; no JNI, no wire format. `RootView`
  owns the singleton `AppModel` and installs an `AppEventDispatch` action
  via `\.dispatch`. `AppState` itself is the `@Observable final class`;
  descendants take it as a parameter and rely on per-property tracking
  for invalidation. Events flow back through `\.dispatch` — the model
  is invisible below the root.
- Android: `JavaUIActor` global actor + a `Bridge` namespace plus an
  `AndroidCommands` pump. The wire is typed primitives end-to-end — no
  JSON. Mutations are one typed thunk per `AppEvent` case
  (`appcoreToggleRead`, `appcoreOpenStory`, `appcoreRefresh`, plus the
  awaitable `appcoreRefreshAwait` for pull-to-refresh). Reactive reads
  use fused `appcoreObserveGet*` thunks: each atomically registers a
  per-property dependency and returns the current value in one JNI hop;
  Kotlin's `BridgedProperty<T>` + `rememberSwiftObserved` re-arm on
  every `onChange`. `[Story]` crosses as an opaque `Int64` peer
  (`StoriesSnapshotPeer` retained via `Unmanaged`); Kotlin walks
  per-field accessors and releases the peer in `finally`. `searchQuery`
  is two-way: Compose drives writes via `appcoreSetSearchQuery`,
  authoritative reads come back via `appcoreObserveGetSearchQuery`.
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
- **No JSON across JNI.** All values cross as typed primitives. Complex
  collections (`[Story]`) cross as Skip-style opaque peer pointers
  (`Int64` from `Unmanaged.passRetained`) plus per-field accessor
  thunks; the eager Kotlin walk materialises a `List<Story>` and
  releases the peer in `finally`. See `StoriesSnapshotPeer.swift`.
- **No support for low-end / Intel Mac AVDs.** Only arm64-v8a is built.
- **Not a published package.** `swift-java` is a path dependency; nothing
  here is meant to be `swift package add`-ed.
- **No cold-start push.** With per-property `appcoreObserveGet*`
  thunks, each composable reads the current value at registration
  time — there's no asynchronous push channel that needs priming.
  `LaunchedEffect(Unit)` in `StoryScreen` fires
  `dispatchAwait(AppEvent.Refresh)` on first appear to populate the
  front page; before that the per-property reads return their zero
  values (`isLoading=false`, empty stories, etc.).
  `BridgePerfTest.a_coldStart_…` is the regression guard.

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
  *bodies* are `#if canImport(Android)`-gated (no-ops or `fatalError`
  on macOS); only the signatures need to compile cross-platform.
  `Bridge.swift`, `JavaUIActor.swift`, `LooperExecutor.swift`,
  `AndroidCommands.swift`, and `StoriesSnapshotPeer.swift` are wrapped
  end-to-end in `#if canImport(Android)` — they're internal, not
  jextract-scanned, and only referenced from the gated thunk bodies,
  so they don't need to exist on macOS at all. On the macOS host build
  `AppCoreAndroid` collapses to the public-API signatures + the
  cross-platform `CommandSink` / `ObservationCallback` /
  `AndroidCompletion` protocols.
- There is exactly one `AppModel` per process. `AppCoreNative` exposes
  the entry points (`appcoreCreate`, `appcoreToggleRead`,
  `appcoreOpenStory`, `appcoreRefresh`, `appcoreRefreshAwait`,
  `appcoreSetSearchQuery`, the `appcoreObserveGet*` family — including
  `appcoreObserveGetStoriesHandle` and the per-field `appcoreStory*` +
  `appcoreStoriesRelease` accessors — and `appcoreDestroy`). All hop
  into the `@JavaUIActor`-isolated `Bridge` namespace via
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
- **Per-composable observation is the recomposition mechanism.** Each
  Compose composable reading a Swift property uses `BridgedProperty<T>`
  + `rememberSwiftObserved` (`SwiftObservable.kt`) to call a fused
  `appcoreObserveGet*` thunk. Each call atomically registers a
  `withObservationTracking` scope on the read properties AND returns
  the current value — so the composable gets a `MutableState<T>` that
  re-arms on every `onChange` by calling the thunk again. Compose
  recomposes only the composables that read the property that changed
  (per-property granularity, not whole-screen). For `[Story]` the
  same shape applies: `appcoreObserveGetStoriesHandle` returns an
  `Int64` peer pointer; the Kotlin closure walks per-field accessors
  to materialise a `List<Story>` and releases the peer in `finally`.
  No JSON, no string parsing, no reused buffers across emissions.
- **Search-query writes are NOT events — they're per-property bridged.**
  Both platforms drive `state.searchQuery` directly: iOS via `@Bindable`
  + `$state.searchQuery`, Android via the per-property JNI setter
  `appcoreSetSearchQuery` and the fused observe-and-read thunk
  `appcoreObserveGetSearchQuery`. Swift is the single source of truth;
  Compose's `TextFieldState` owns the typing buffer locally and writes
  through to Swift via a `snapshotFlow` LaunchedEffect.
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
  - Android `Bridge`: `AndroidCommands` owns its own
    `Task<Void, Never>?` field internally; `Bridge` itself owns only
    the `queryWatcherTask`. Both are spawned in `Bridge.attach()` and
    cancelled in `Bridge.detach()`. Per-composable observation Tasks
    (registered via the fused `appcoreObserveGet*` thunks) live for
    the lifetime of a single `withObservationTracking` arm and do
    not need explicit lifecycle plumbing on the bridge side. Under
    `@JavaUIActor` global-actor isolation, Task closures inherit the
    same isolation, so capturing non-Sendable references stays
    in-region.
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
    the `appcoreObserveGet*` family, the fire-and-forget event thunks
    (`appcoreToggleRead`, `appcoreOpenStory`, `appcoreRefresh`), and
    `appcoreDestroy` execute their actor work synchronously and only
    return after the mutation has been enqueued (or, for fused reads,
    after the read has been performed). The dispatch arms run on a
    `Task` they spawn, so the Swift-side fetch happens asynchronously,
    but the JNI thunk itself returns promptly.
  - **Awaitable variants exist where iOS does too.** Pull-to-refresh
    needs the indicator visible for the full fetch lifetime, so
    `appcoreRefreshAwait(completion:)` calls
    `Bridge.enqueueAwaitableDispatch(.refresh, completion:)` which
    spawns a Task, awaits the async dispatch, and fires the
    `AndroidCompletion` so the Kotlin `awaitWithCompletion {}`
    helper resumes its `suspendCancellableCoroutine`. Toggle and open
    are fire-and-forget on both platforms, so they don't ship an
    `*Await` variant.
  - **Off-UI-thread JNI calls trap — this is intentional.** Compose
    dispatches all user events from the UI thread, and the bridge's
    executor *is* the UI thread, so `assumeIsolated` is sound. The
    contract is "JNI thunks may only be called from the UI thread";
    a background coroutine calling `AppCoreAndroid.appcoreToggleRead(...)`
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
    `Bridge.swift`, `AndroidCommands.swift`, and
    `StoriesSnapshotPeer.swift` are similarly gated; the JNI thunks
    in `AppCoreNative.swift` have `#if canImport(Android)`-gated
    bodies. On macOS, the entire bridge collapses to the public-API
    signatures + the cross-platform `CommandSink` /
    `ObservationCallback` / `AndroidCompletion` protocols — jextract
    still scans these so the Java surface generates correctly. We
    don't need a fake macOS impl because `AppCoreTests` doesn't
    exercise the bridge primitives.
- **`observeGet`'s `onChange` must Task-hop, not `assumeIsolated`.**
  `withObservationTracking`'s `onChange` fires synchronously *inside*
  the property's `willSet`, before the mutation has committed. Kotlin's
  `onChange` re-enters Swift to re-register tracking via another
  `appcoreObserveGet*` call — and that nested read, if synchronous,
  sees the pre-mutation value (the getter still returns the old backing
  storage during willSet). The result is `MutableState` written with
  stale values: `isLoading=false` is observed as `true`, the spinner
  stays asserted forever, stories never paint. The `onChange` body in
  `observeGet` therefore enqueues `callback.onChange()` via
  `Task { @JavaUIActor in … }` so the re-registration happens after
  the writer's setter unwinds and the recursive read sees the final
  committed state. The contract is documented on `ObservationCallback`.
  Don't change this back to `JavaUIActor.assumeIsolated { callback.onChange() }`.
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
    (Swift) and matching arm in `AppModel.dispatch`; (b) new public
    typed thunk on `AppCoreNative.swift`
    (`appcoreFooBar(arg: String)` etc.) calling
    `Bridge.enqueueDispatch(.fooBar(arg: arg))`; (c) matching
    plain Kotlin sealed-class variant on `AppEvent` in
    `AppModelHolder.kt`; (d) new `when` arm in
    `AppModelHolder.dispatch` (and `dispatchAwait` if pull-to-refresh-
    style). The wire is typed primitives — no JSON, no MetaCodable, no
    `@SerialName`. If the iOS UI also needs an awaitable variant, add
    a sibling `appcoreFooBarAwait(arg:, completion:)` thunk that calls
    `Bridge.enqueueAwaitableDispatch(.fooBar(arg:), completion:)`.
  - **Core → UI command** (one-shot, like `presentURL`): add a `case`
    to `AppCommand`, a `switch` arm in `AndroidCommands.start()` that
    calls a new typed method on `CommandSink`, and the matching method
    on the `CommandSink` Swift protocol. Kotlin's `AppModelHolder`
    overrides the new method and constructs the matching Kotlin
    `AppCommand` data class for downstream consumers. No JSON.
  - **Per-property bridged primitive** (continuously two-way bound to
    a UI control, like `searchQuery`): (a) make the `@Observable`
    property publicly settable on `AppState`; (b) on Android, add an
    `appcoreSetX(value:)` setter thunk and an
    `appcoreObserveGetX(callback:) -> X` fused observe-and-read thunk,
    both using `Bridge.handleSetX` / `observeGet(\.x, callback:)`;
    (c) on Kotlin, expose a new `BridgedProperty<X>` on
    `AppModelHolder` calling the fused thunk, and a `setX(...)` write
    helper; (d) on iOS, just bind via `$state.x`. The host's existing
    `searchQuery` watcher loop only picks up new properties if you
    wire them through `runFetch` or another shared trigger — usually
    each per-property primitive wants its own host-side reaction.
  - **Per-property bridged collection** (a frequently-updated complex
    snapshot, like `[Story]`): same shape as primitives but with a
    peer wrapper. Define a `final class XSnapshotPeer: @unchecked
    Sendable { let value: X }`, an `appcoreObserveGetXHandle(callback:)
    -> Int64` fused thunk that retains a peer via
    `Unmanaged.passRetained`, per-field `appcoreXFoo(handle:, index:)`
    accessor thunks, and an `appcoreXRelease(handle:)` thunk. Kotlin's
    `BridgedProperty` closure walks the peer eagerly and releases in
    `finally`. Pattern modelled on Skip's peer-handle bridge but kept
    bespoke because there are only a handful of bridged collections.
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
