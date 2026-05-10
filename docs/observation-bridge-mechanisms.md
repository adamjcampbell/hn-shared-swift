# Observation bridge: mechanism options

This document compares five ways to surface a Swift `@Observable` property
as Compose state on Android. It's an architectural reference for the
existing `SwiftState` / `SwiftBinding` design, not a how-to guide.

The current implementation (`android-app/.../state/SwiftState.kt` + the
Swift-side `observeGet` in `AppCoreNative.swift`) uses **Option E —
`Observations` AsyncSequence**, which sidesteps the willSet race at the
source rather than working around it on the consumer side. Options A–D
remain valid alternatives; D in particular was the production
implementation before E was viable.

---

## Background: the willSet race

Swift's observation framework is built around `withObservationTracking`:

```swift
withObservationTracking {
    read(state)              // properties read here are tracked
} onChange: {
    callback.onChange()      // fires once when any tracked property mutates
}
```

The non-obvious part is **when** `onChange` fires. Each `@Observable`
property setter is implemented as:

```swift
set {
    _$observationRegistrar.withMutation(of: self, keyPath: \.x) {
        _x = newValue        // ← actual mutation
    }
}
```

`withMutation` does:

1. Call `willSet(keyPath)` — fires registered onChange callbacks.
2. Run the mutation closure (`_x = newValue`).
3. Call `didSet(keyPath)`.

So `onChange` runs **inside** willSet, **before** the mutation has
committed. The property's getter still returns the old backing storage.

### What that means for re-registration

A typical Compose adapter wants to re-arm tracking on every change:

1. `onChange` fires.
2. The adapter wants to register a new `onChange` for the next mutation.
3. Re-registering means calling `withObservationTracking { read(state) } …`
   again, which **reads the property**.

If step 3 happens synchronously inside step 1, the read returns
**pre-mutation** state. The whole bridge appears to work but the values
that reach Compose are always one update behind. Symptom we hit during
development:

- `state.isLoading = true` → onChange → re-arm reads `isLoading`,
  sees `false` (the pre-mutation value) → spinner reads `false`.
- Eventually `state.isLoading = false` → onChange → re-arm reads
  `isLoading`, sees `true` → spinner reads `true`.
- Spinner stays asserted forever, stories never paint.

Apple's `Observations` (SE-0475, iOS 26+) avoids this by emitting at
"transaction end" instead of inside willSet. Pre-iOS-26 code (and our
JNI bridge) has to work around it explicitly. The local
`ObservedKeyPath<Root, Value>` (`AppCore/Sources/AppCore/Observed.swift`)
solves it for `AsyncSequence` consumers via a `Task.yield()` after the
suspension. The Android bridge has the same problem but a different
shape — the consumer is Compose, not an `AsyncSequence`.

The four options below are different ways to handle this constraint:
**defer the re-registration past willSet**, somehow.

---

## Option A — Counter-backed `State<T>`, no cache

```kotlin
class TrackedSwiftState<T>(private val track: (OnChange) -> T) : State<T> {
    private val tick = mutableIntStateOf(0)

    override val value: T get() {
        tick.intValue                                   // snapshot read → tracked
        return track(OnChange { tick.intValue++ })     // each read re-arms + fetches
    }
}
```

**Mechanism.** Compose tracks `tick` reads automatically (more on that
below). When Swift fires onChange, the callback synchronously increments
`tick` from the JNI thread. Compose's snapshot apply notification fires;
the recomposer schedules invalidation for the next frame. On
recomposition, `value` is read again, calling `track(...)` to fetch the
post-mutation Swift state and registering a fresh tracker.

**willSet race avoided?** Yes — `onChange` only writes to a Compose
state cell (`tick.intValue++`). It doesn't read Swift. The Swift read
happens during recomposition, after willSet has unwound.

**Downsides.**
- Every `.value` read calls `track(...)` → 1 JNI call per read.
- Multiple readers in the same frame each register their own tracker —
  multi-reader churn proportional to the number of read sites.

---

## Option B — Counter-backed `State<T>` with lazy cache

```kotlin
class TrackedSwiftState<T>(private val track: (OnChange) -> T) : State<T> {
    private val tick = mutableIntStateOf(0)
    private var lastTick = 0
    private var cached: T = track(OnChange { tick.intValue++ })

    override val value: T get() {
        val t = tick.intValue                         // snapshot read → tracked
        if (t != lastTick) {
            lastTick = t
            cached = track(OnChange { tick.intValue++ })
        }
        return cached
    }
}
```

**Mechanism.** Same dirty-signal as A (sync `tick.intValue++` from
within willSet), but cache the value within a tick generation. The
constructor fetches eagerly so `cached` is initialized as `T` (no
sentinel, no unchecked cast).

**willSet race avoided?** Yes, same as A.

**Cost per Swift change:** 1 atomic int increment.
**Cost per `.value` read:** Free (cache hit) or 1 JNI call (first read
after a tick change).
**Multi-reader scaling:** All readers share the cache; only the first
post-change read pays the JNI cost.

---

## Option C′ — RecomposeScope tracking with sync invalidate + lazy cache

```kotlin
class TrackedSwiftState<T>(private val track: (OnChange) -> T) {
    private val scopes = Collections.newSetFromMap(WeakHashMap<RecomposeScope, Boolean>())
    @Volatile private var cached: T = track(OnChange { onChange() })
    @Volatile private var dirty = false

    @Composable
    fun read(): T {
        synchronized(scopes) { scopes.add(currentRecomposeScope) }
        if (dirty) {
            cached = track(OnChange { onChange() })
            dirty = false
        }
        return cached
    }

    private fun onChange() {
        dirty = true                                   // sync, no Swift read
        val toInvalidate: List<RecomposeScope>
        synchronized(scopes) { toInvalidate = scopes.toList(); scopes.clear() }
        toInvalidate.forEach { it.invalidate() }       // sync invalidation
    }
}
```

**Mechanism.** Bypass the snapshot system. Each `read()` captures the
currently-recomposing scope; `onChange` directly invalidates every
captured scope. The value is fetched lazily on the first read after each
mutation.

**willSet race avoided?** Yes — `onChange` only sets a flag and calls
`invalidate()`. Both are non-Swift-reading. `invalidate()` marks the
scope dirty without reading anything; the actual Swift read happens
during recomposition (next frame), after willSet has unwound.

**Cost per Swift change:** N `invalidate()` calls (N = current readers).
**Cost per read:** Free for cache hits, 1 JNI call for the first read
after a change.
**Multi-reader scaling:** Reasonable, though scope tracking is manual.

**Drawbacks.**
- `read()` must be `@Composable` because `currentRecomposeScope` is
  `@Composable` API. This breaks the standard `State<T>.value` ergonomic
  — the property delegate `by` only works in `@Composable` context, and
  the value can't be read inside non-`@Composable` lambdas like
  `LazyListScope.() -> Unit`.
- Manual `WeakHashMap<RecomposeScope, _>` and `synchronized` blocks
  reimplement bookkeeping that the snapshot system already does.
- Every read site has to be inside a `@Composable` function.

---

## Option D — `Handler.post`

```kotlin
private class SwiftBinding<T>(private val track: (OnChange) -> T) {
    private var active = true
    val state: MutableState<T> = mutableStateOf(observe())
    fun dispose() { active = false }
    private fun observe(): T = track(OnChange {
        mainHandler.post { if (active) state.value = observe() }
    })
}
```

**Mechanism.** Defer the re-registration to the next main-looper
iteration via `Handler.post`. By the time the posted runnable runs, the
Swift writer's setter has unwound — `observe()` reads post-mutation
state and writes it to the `MutableState`, triggering Compose's normal
recomposition pipeline.

**willSet race avoided?** Yes — the post defers the read past willSet.

**Cost per Swift change:** 1 `Handler.post` enqueue + 1 looper hop +
1 JNI call (the re-arm `track`).
**Cost per `.value` read:** Free (standard MutableState read).
**Multi-reader scaling:** One tracker per binding, all readers share
the cached `MutableState`.

---

## Option E — `Observations` AsyncSequence with cancel-on-dispose (current implementation)

```swift
@JavaUIActor
private func observe<T: Sendable>(
    _ read: @escaping @Sendable (AppState) -> T,
    callback: some OnChange,
) -> Int64 {
    let task = Task {
        for await _ in Observations({ read(Bridge.appModel.state) }).dropFirst() {
            callback.onChange()
        }
    }
    return Bridge.registerObservation(task)
}

public func appcoreCancelObservation(token: Int64) {
    JavaUIActor.assumeIsolated { Bridge.cancelObservation(token) }
}
```

```kotlin
class SwiftState<T>(
    val observe: (OnChange) -> Long,
    val read: () -> T,
)

private class SwiftBinding<T>(swiftState: SwiftState<T>) {
    private val read = swiftState.read
    val state: MutableState<T> = mutableStateOf(read())
    private val token: Long = swiftState.observe(OnChange { state.value = read() })
    fun dispose() { AppCoreAndroid.appcoreCancelObservation(token) }
}
```

**Mechanism.** Swift's `Observations` AsyncSequence (SE-0475) emits at
**transaction end** — *after* the property's didSet. The bridge spawns
one long-lived Task per binding that iterates the sequence and fires
`callback.onChange()` on every change. The Task is registered with the
`Bridge` registry, which returns a token; Kotlin holds the token and
calls `appcoreCancelObservation(token)` on `SwiftBinding.dispose()`.
Cancellation tears the Task down immediately — the for-await loop
exits, the OnChange capture is released, the JNI global ref drops, and
GC reclaims the chain.

`Bridge.detach` (called by `appcoreDestroy`) also iterates the registry
and cancels any tokens still outstanding, so tests that destroy without
explicit cancellation don't leak Tasks across runs.

**willSet race avoided?** Yes — the emission machinery doesn't run
inside the setter's stack at all. By the time `onChange` fires the
mutation has committed, so the synchronous re-read inside Kotlin's
`OnChange` body returns post-mutation state.

**Lifecycle.** Per binding: 1 register call + 1 initial read on
construction; 1 read per emission; 1 cancel on dispose. Tasks are
torn down promptly on dispose — no "leak until next mutation"
window.

**Cost per Swift change:** 1 `Task` continuation resumption (≈1 looper
job) + 1 JNI call (the read).
**Cost per `.value` read:** Free (standard MutableState read).
**Multi-reader scaling:** Same as D — one tracker per binding, all
readers share the cached `MutableState`.

**Constraints.**
- `T` must be `Sendable` (Observations' `Element` requirement). The
  `read` closure must be `@escaping @Sendable`. All current callers
  satisfy this — primitive returns and key-path-style closures.
- Requires `Observations` in the Swift stdlib. Available in Swift 6.2+
  (Android SDK 6.3 has it; on Apple platforms `Observations` is
  iOS 26+, which is why iOS-17-floor consumers in `AppCore` use the
  local `ObservedKeyPath` fallback in `Observed.swift`).
- Per-property API is now a pair: `appcoreObserve*(callback) -> Int64`
  and `appcoreReadX() -> T`. The previous fused `appcoreObserveGet*`
  is gone. Slight increase in thunk surface (5 reads + 1 cancel),
  in exchange for prompt cleanup and an end to the Kotlin-side
  `active` flag.

**Trade-offs vs D.** E is strictly cleaner: no `Handler` dependency,
no Looper post per emission, no `active` flag, no "leak until next
mutation" window, and no comments explaining "why we defer". The cost
is being on a Swift toolchain that has `Observations` and accepting
the `T: Sendable` constraint on observed types. For this app, both
are non-issues.

---

## How non-`@Composable` `.value` getters get tracked anyway

Options A, B, and D all use a non-`@Composable` `value: T get()` and
still participate in Compose's read tracking. This isn't magic — it's
the snapshot system.

`SnapshotMutableStateImpl<T>` (the impl `mutableStateOf` returns)
implements `value`'s getter as:

```kotlin
override var value: T
    get() = next.readable(this).value      // SnapshotState.kt:142
```

`readable()` (in `Snapshot.kt:2121`) does:

```kotlin
public fun <T : StateRecord> T.readable(state: StateObject): T {
    val snapshot = Snapshot.current
    snapshot.readObserver?.invoke(state)   // ← THE TRACKING HOOK
    return readable(this, snapshot.snapshotId, snapshot.invalid) ?: ...
}
```

So every read of a snapshot state — `mutableStateOf` or
`mutableIntStateOf` or any other `StateObject` — fires
`Snapshot.current.readObserver`. That observer is set up by the
surrounding *composition context*, not by the getter itself.

When Compose runs a recomposition, it does roughly (`Snapshot.kt:484`):

```kotlin
Snapshot.observe(
    readObserver = { state -> currentRecomposeScope.recordRead(state) },
    writeObserver = …,
    block = { /* execute composable */ }
)
```

That snapshot's `readObserver` registers any state read during the
block with the current `RecomposeScope`. Later, when that state is
written, Compose looks up which scopes recorded reads of it and
invalidates them.

**So:** if your getter is called from a function eventually invoked
inside a recomposing scope, your `.value` reads are tracked
automatically. The `@Composable` annotation itself doesn't do the
tracking — the surrounding `Snapshot.observe` does. That's why a
custom `State<T>` whose getter reads a `mutableStateOf` (Option B's
`tick`) inherits tracking transparently.

The only API you genuinely *need* `@Composable` for is one that calls
`@Composable` functions itself — `currentRecomposeScope`, `remember`,
`DisposableEffect`. Reading a snapshot state cell from a non-
`@Composable` getter participates in tracking just fine.

---

## Comparison

| | A: counter, no cache | B: counter + cache | C′: scope-set + invalidate | D: Handler.post | E: Observations (current) |
|---|---|---|---|---|---|
| willSet race avoided | ✓ (deferral) | ✓ (deferral) | ✓ (deferral) | ✓ (deferral) | ✓ (no willSet involvement at all) |
| Swift-side primitive | `withObservationTracking` | `withObservationTracking` | `withObservationTracking` | `withObservationTracking` | `Observations` |
| Frame at which Compose recomposes | Next | Next | Next | Next | Next |
| Cost per Swift change | 1 atomic int | 1 atomic int | 1 sentinel + N invalidates | 1 `Handler.post` + 1 JNI | 1 `Task` resume + 1 JNI |
| Cost per read (cached) | 1 JNI (always) | Free | Free | Free | Free |
| Cost per read (cold) | 1 JNI | 1 JNI | 1 JNI | n/a | n/a |
| Multi-reader behaviour | Each read pays JNI | All share cache | All share cache | All share `MutableState` | All share `MutableState` |
| Standard `State<T>.value` API | ✓ | ✓ | ✗ (`@Composable read()`) | ✓ | ✓ |
| Compose API surface used | `mutableIntStateOf` | `mutableIntStateOf` | `currentRecomposeScope` + WeakHashMap | `mutableStateOf` | `mutableStateOf` |
| Swift toolchain requirement | Any | Any | Any | Any | Swift 6.2+ stdlib |
| Implementation size | ~7 lines | ~13 lines | ~25 lines | ~10 lines | ~10 lines (Swift) + ~10 lines (Kotlin) |

### What "synchronous mark-dirty" actually buys you

Options A, B, and C′ signal Compose synchronously inside Swift's
willSet. Option D defers via `Handler.post`. The difference is on the
order of microseconds. Compose's recomposer is bound to Choreographer —
all four schedule the recomposition for **the same frame**. The
"synchronous mark-dirty" property only matters if a non-Compose
subscriber to the snapshot system needs to react before the next frame,
which doesn't happen in this codebase.

---

## Trade-offs

**A is the simplest** but pays a JNI call on every `.value` read. Fine
for a binding read once per frame; bad for a binding read in many
places.

**B is the cleanest `withObservationTracking`-based alternative.**
Synchronous dirty signal, lazy cache, standard `.value` API. About 5
extra lines vs D for the cache bookkeeping.

**C′ is the most direct invalidation path** but trades the standard
state-read API for `@Composable` reads. The lifecycle plumbing
(WeakHashMap, synchronized, scope re-capture across recompositions)
adds up to more code than B and gates downstream uses on always being
inside a `@Composable` context.

**D works around the willSet race** with a `Handler.post` deferral.
Simple, public APIs, well-understood. The looper-hop cost is invisible
at this app's mutation rate. Was the production implementation before
E.

**E (current)** sidesteps the willSet race at the source by using
`Observations` — the AsyncSequence emits at transaction end, post-
didSet, so synchronous re-arm in Kotlin reads fresh state directly.
No `Handler` dependency, no deferral, no "why this works" comment block
explaining a workaround. Requires Swift 6.2+ stdlib and `T: Sendable`
on observed types — both met for this codebase.

---

## When to switch

If E ever stops being viable (downgraded toolchain, observed types
that can't be `Sendable`):

- **D** is the most conservative fallback — same Compose surface, same
  multi-reader story, just adds the `Handler.post` deferral back.
- **B** if you want to drop the `Handler` dependency entirely while
  keeping `withObservationTracking`. More moving parts than D in
  exchange for slightly tighter dirty-signal timing.
- **C′** is interesting as a "what if we bypassed the snapshot system
  entirely?" exploration but the cost exceeds the benefit for this
  bridge.
- **A** is academic — the per-read JNI cost makes it impractical.

---

## Recommendation

Stay on **E**. The combination of "no willSet race to work around" and
"simplest implementation of any option" makes it the obvious choice
once `Observations` is available. Future iOS-shared code will hit the
same crossover when iOS 26 becomes the deployment floor — at which
point `ObservedKeyPath` in `AppCore/Sources/AppCore/Observed.swift`
also collapses to plain `Observations { … }`.

If a regression ever forces a fallback, the order of preference is
**D → B → C′ → A**. D is simplest and uses no esoteric APIs.

---

## Source pointers

- Apple's `Observations` AsyncSequence — SE-0475. Emits at
  transaction end (post-didSet), avoiding the `withObservationTracking`
  willSet race entirely.
- `androidx.compose.runtime.snapshots.Snapshot.readable` —
  `Snapshot.kt:2121`. Fires `readObserver` on state read.
- `Snapshot.observe(readObserver, writeObserver, block)` —
  `Snapshot.kt:484`. How Compose sets up read tracking around a
  composition.
- `SnapshotMutableStateImpl<T>` — `SnapshotState.kt:136`. The standard
  `mutableStateOf` impl. Demonstrates the `next.readable(this).value`
  pattern that any custom State<T> can mirror.
- `androidx.compose.runtime.RecomposeScope.invalidate()` — public API
  to mark a scope dirty. Used by Option C′.
- `androidx.compose.runtime.currentRecomposeScope` — `@Composable`
  property returning the immediate enclosing scope. Used by Option C′.

Local references:
- `AppCore/Sources/AppCoreAndroid/AppCoreNative.swift` — the
  `appcoreObserveGet*` thunks and the `observeGet` helper that does
  the Swift-side `withObservationTracking { … } onChange: { … }` setup.
- `AppCore/Sources/AppCoreAndroid/OnChange.swift` — JNI mirror of the
  onChange closure. Documents the thread contract.
- `AppCore/Sources/AppCore/Observed.swift` — `ObservedKeyPath`, the
  `AsyncSequence`-based equivalent of this bridge for iOS-17-floor
  consumers. Solves the same willSet race for a different consumer
  shape (uses `Task.yield()` after the suspension).
- `android-app/.../state/SwiftState.kt` — the live implementation
  (Option D).
