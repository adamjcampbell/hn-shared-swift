# Adopting SkipFuse

In 2026-05 this repo migrated from a hand-written `swift-java jextract`
bridge to [SkipFuse](https://skip.dev). Net diff: **+180 / −1,968 LOC**
across 31 files. This doc captures what changed, why, and the gotchas
worth knowing before you touch the bridge again.

## What we wanted

The shape we'd been aiming for since day one:

- A single `@Observable` Swift class as the source of truth for both
  platforms.
- iOS reads it directly via SwiftUI's tracking; Android reads it
  directly inside `@Composable`s with the same recompose-on-change
  semantics.
- `async` Swift functions look like `suspend` from Kotlin.
- `AsyncStream<T>` looks like `kotlinx.coroutines.flow.Flow<T>` from
  Kotlin.
- `[Story]` looks like `List<Story>` from Kotlin.
- Adding a new `@Observable` property is one Swift line, not a 30-line
  change spread across three files.

The hand-written bridge got close on the first three but never on the
fourth — every new property meant a thunk, a typed `*OnChange`
protocol, and a Kotlin `SwiftState<T>` declaration. SkipFuse delivers
all four for free.

## What it actually looks like

iOS — Core is consumed directly:

```swift
@Bindable var model: Model
TextField("Search", text: $model.searchQuery)
LazyVStack { ForEach(model.feedStories) { StoryRowView(story: $0) } }
.task { await sendMessage.run(.refresh) }
```

Android — Compose now reads the bridged Core directly. No
`SwiftState`, no `*OnChange`, no `appcoreObserveX`:

```kotlin
@Composable
fun StoryScreen(core: Core) {
    val model = core.model
    val sendMessage = core.sendMessage

    LaunchedEffect(Unit) { sendMessage.send(Message.refresh) }

    TextField(
        value = model.searchQuery,
        onValueChange = { model.searchQuery = it },
    )
    LazyColumn {
        items(model.feedStories.kotlin() as List<StoryRow>) { story ->
            StoryRow(story)
        }
    }
}
```

`model.searchQuery = it` runs the Swift setter through JNI, which
fires `@Observable`'s willSet, which SkipFuse routes through Compose's
`MutableStateBacking` snapshot system, which schedules recomposition
of every Composable that read `searchQuery`.

## How it works

SkipFuse intercepts the standard `Observation` framework's
`ObservationRegistrar`. When Swift's macro-expanded getter does
`registrar.access(self, keyPath: \.x)`, SkipFuse JNI-calls
`MutableStateBacking.access(index)` on the Kotlin side, which reads
a Compose `MutableState<Int>` cell. That read registers the Composable
as a dependency of the property. On mutation,
`registrar.willSet(...)` JNI-calls `MutableStateBacking.update(index)`,
which increments the cell, which Compose's snapshot system turns into
a recompose for every dependent Composable.

The mechanism is in
[`Observation.swift`](https://github.com/skiptools/skip-android-bridge/blob/main/Sources/SkipAndroidBridge/Observation.swift)
and
[`MutableStateBacking.swift`](https://github.com/skiptools/skip-model/blob/main/Sources/SkipModel/MutableStateBacking.swift)
in the Skip projects.

## Actor isolation under SkipFuse

The migration plan abandoned per-platform actor pinning (`@MainActor`
on iOS, `@JavaUIActor` on Android) on the assumption that SkipFuse
couldn't handle actor-isolated bridged classes — that was the lesson
from the earlier `swift-java jextract` experiments, where adding
`@JavaUIActor` to the model class produced ~20 compile errors in
auto-generated cdecl thunks. **The assumption doesn't hold for
SkipFuse**: its bridge codegen is fully actor-aware, and Apple's
`MainActor` is plumbed to Android's main looper at runtime. You can
pin to `@MainActor` and recover the compile-time isolation safety the
old `JavaUIActor` design was after, with no extra plumbing.

### What `skipstone` does with `@MainActor`

Annotate a bridged class with `@MainActor` and `skipstone` wraps
every cdecl thunk's body in `SkipBridge.assumeMainActorUnchecked
{ ... }`:

```swift
@MainActor
@Observable
public final class Model {
    public var searchQuery: String = ""
    // …
}
```

```swift
// Generated Model_Bridge.swift
@_cdecl("Java_hacker_news_reader_Model_Swift_1searchQuery")
public func Model_Swift_searchQuery(...) -> JavaString {
    let peer_swift: Model = Swift_peer.pointee()!
    return SkipBridge.assumeMainActorUnchecked {
        return peer_swift.searchQuery.toJavaObject(options: [])!
    }
}

@_cdecl("Java_hacker_news_reader_Core_Swift_1callback_1sendMessage_11")
public func Core_Swift_callback_sendMessage_1(...) {
    let f_callback_swift = ...
    let peer_swift: Core = Swift_peer.pointee()!
    let p_0_swift = Message.fromJavaObject(p_0, options: [])
    Task {
        await peer_swift.sendMessage(p_0_swift)
        f_callback_swift()
    }
}
```

`assumeMainActorUnchecked` is literally `MainActor.assumeIsolated`
(`skip-bridge/Sources/SkipBridge/BridgeSupport.swift:101`). Async
dispatches stay simple — `Task { await peer.sendMessage(...) }` —
because under SE-0461 the await hops to MainActor automatically.

### Why MainActor reaches Android's main thread

Apple's `MainActor` schedules onto libdispatch's main queue. Android
doesn't drain libdispatch by default. Skip's `swift-android-native`
bridges the gap: `AndroidLooper.setupMainLooper()` (called during
`AndroidBridgeBootstrap.initAndroidBridge()` at app launch — visible
in logcat as `swift.android.native/AndroidLooper: setupMainLooper`)
registers libdispatch's main queue file descriptor with Android's
`ALooper`. When the main queue has work, the looper's callback runs
`CFRunLoopRunInMode(...)` which drains both CFRunLoop and the
dispatch main queue. Net effect: jobs scheduled to MainActor execute
on Android's main looper thread.

This is the same trick the old `JavaUIActor` + `LooperExecutor`
pulled, hand-written. SkipFuse's runtime ships the equivalent,
upstream.

### Runtime guarantees if you pin

- Compose calls from `Dispatchers.Main` (the typical case) land on
  the main looper, which IS MainActor's executor → the
  `assumeIsolated` precondition passes and the access succeeds.
- Background-thread JNI calls (e.g. a `Dispatchers.IO` coroutine
  accidentally invoking a bridged member) trap with `Incorrect actor
  executor assumption; expected MainActor` — same dynamic check the
  old `JavaUIActor.assumeIsolated` did.
- The Compose `MutableStateBacking` cells are still updated from
  whatever thread the willSet runs on (MainActor under pinning,
  arbitrary under nonisolated); Compose's snapshot system handles
  both correctly.

### Verified empirically

`Core` is a `@MainActor` `struct` bridged via `// SKIP @bridgeMembers`.
Its `let` fields hold the `Model` class, the commands stream, and the
`SendMessageAction` (which holds the only out-of-module reference to
the internal `Engine` actor). The Kotlin/Compose side reads
`core.model.foo` through SkipFuse's `@Observable` interception without
indirection; `@State private var core = makeCore()` in
`HackerNewsReaderApp` is the single owning location on iOS.

`Engine` is a real `actor` whose `unownedExecutor` is borrowed from an
`isolation: any Actor` init parameter (SE-0392). Production passes
`MainActor.shared`, so `Engine`'s executor IS MainActor's at runtime
— `await engine.sendMessage(...)` is a virtual hop with no real
thread switch. Non-`Sendable` `Model` flows into `Engine` via SE-0414
region isolation and back out to the `Core` through a one-shot
`@unchecked Sendable` box scoped to `makeCore`. Mutators live on
`Engine`; `Model` itself is a plain `@Observable final class`. The
production design contains **zero** `@unchecked Sendable` and zero
`nonisolated(unsafe)` outside that one scoped box.

Tests construct `Engine` with a `TestActor` `isolation:` so each test
runs on its own `DispatchSerialQueue` executor and the suite
parallelises across instances.

The empirical run:

- A clean `swift build` (the `// SKIP @bridge` markers stay the same).
- A clean `skip export` — `skipstone` regenerates the bridge thunks
  with the `assumeMainActorUnchecked` wrapping.
- A clean `./gradlew :app:assembleDebug`.
- An app that boots, fetches HN stories, and handles search end-to-end
  with no behaviour change.

## Gotchas worth knowing

1. **Per-type `// SKIP @bridgeMembers` is the low-noise default** —
   one annotation on the type declaration bridges every public member
   (stored vars, computed vars, mutating funcs, init). Reach for
   per-member `// SKIP @bridge` only when you want a strict subset, and
   `// SKIP @nobridge` to opt a single member out (e.g. an init that
   takes an unbridged type). **`// SKIP @bridge` at the type level
   alone is not equivalent** — it generates a class with no field
   accessors (only `Identifiable.id` as `ObjectIdentifier`).
2. **Kotlin toolchain must match SkipFuse's exported AAR metadata
   version.** SkipFuse 1.8.x emits Kotlin 2.3.0 metadata. Your Android
   project must use Kotlin 2.3+ or you get
   `Class 'app.core.X' was compiled with an incompatible version of
   Kotlin`.
3. **`kotlin-reflect` is required at runtime.** `ProcessInfo.launch()`
   uses `kotlin.reflect.full.KClasses` to find and invoke the bridge
   bootstrapper. Without it, the app crashes on first launch with
   `ClassNotFoundException`. Add `implementation
   "org.jetbrains.kotlin:kotlin-reflect:2.3.0"`.
4. **`suspend fun` uses `suspendCoroutine`, not
   `suspendCancellableCoroutine`.** Kotlin coroutine cancellation does
   *not* propagate to the underlying Swift Task. The hand-written
   bridge wired `cont.invokeOnCancellation { appcoreCancelTask(token) }`;
   that wiring is gone now. For dispatches that need cooperative
   cancellation (e.g. pull-to-refresh aborted by navigation), wrap
   manually or file an upstream issue with skip-bridge.
5. **`Story` is a peer-backed Kotlin class, not a data class.** Each
   property read crosses JNI. For an HN reader (200ish stories) this
   is fine. For a chat app with 10k messages, profile before assuming
   it works at scale; Skip supports custom value-class projections.
6. **`AsyncStream<T>` requires `.kotlin()` to convert to `Flow<T>`.**
   The bridged property has type `skip.lib.AsyncStream<T>` which
   implements `KotlinConverting<Flow<T>>`. Call `.kotlin()` before
   `.collect`.

## How the build runs

```sh
# Build the APK. The `skipExport` Gradle task in
# android-app/app/build.gradle.kts is a `preBuild` dependency that
# re-runs `skip export` whenever Swift sources or Package.swift change;
# Gradle's up-to-date check skips it otherwise. One invocation
# transitively packages the HackerNews dependency target into a
# separate AAR alongside the HackerNewsReader one.
cd android-app
./gradlew :app:assembleDebug
```

`skip-libs/` is gitignored — it's a build artefact regenerated from
the Swift sources. The APK packages the `.aar` files directly via
`debugImplementation(fileTree(...))`.

To trigger the export without a full Gradle build:

```sh
cd HackerNewsReader
skip export --debug --no-ios --module HackerNewsReader -d ../android-app/skip-libs
```

## Ergonomic shape compared

|                         | Hand-written bridge       | SkipFuse                       |
|-------------------------|---------------------------|--------------------------------|
| LOC for the bridge      | ~1,180                    | ~35 (mostly bootstrap)         |
| LOC per new `@Observable` property | ~30 Swift + ~4 Kotlin | one Swift line + bridge marker |
| `[Story]` access        | `walkStoriesPeer(peer)` per emission | direct field read via JNI |
| Cancellation on suspend | wired                     | not propagated upstream        |
| APK size impact         | ~99 MB debug              | ~99 MB debug (parity)          |
| Bridge tests            | `BridgePerfTest` cold-start regression | none yet — needs reseeding |
| Per-platform actor pinning | `@MainActor` on iOS, `@JavaUIActor` on Android (custom executor) | One `Engine` actor borrowing `MainActor`'s executor on both — Skip's runtime drains libdispatch from `ALooper` |

## Where the previous bridge lives

Frozen on the `extension-method-bridge-experiment` branch and in
[`docs/historical/`](historical/README.md). Useful as a record of
what we tried; don't try to revive it.
