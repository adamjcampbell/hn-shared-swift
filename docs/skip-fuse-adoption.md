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

iOS — unchanged. AppCore is consumed directly:

```swift
@Bindable var state: AppState
TextField("Search", text: $state.searchQuery)
LazyVStack { ForEach(state.stories) { StoryRow($0) } }
.task { await appModel.dispatch(.refresh) }
```

Android — Compose now reads the bridged AppCore directly. No
`SwiftState`, no `*OnChange`, no `appcoreObserveX`:

```kotlin
@Composable
fun StoryScreen() {
    val appModel = rememberAppModel()
    val state = appModel.state

    LaunchedEffect(appModel) { appModel.dispatch(AppEvent.refresh) }

    TextField(
        value = state.searchQuery,
        onValueChange = { state.searchQuery = it },
    )
    LazyColumn {
        items(state.stories.kotlin() as List<Story>) { story ->
            StoryRow(story)
        }
    }
}
```

`state.searchQuery = it` runs the Swift setter through JNI, which
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

## Gotchas worth knowing

1. **Per-field `// SKIP @bridge` markers are required** on a struct's
   `let` fields — marking just the type generates a class with no
   field accessors. Without the field markers, only `Identifiable.id`
   (as `ObjectIdentifier`) shows up.
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
# Build the AppCore .aar bundle (regenerate after Swift changes).
cd AppCore
skip export --debug --no-ios --module AppCore -d ../android-app/skip-libs

# Build the APK consuming the .aar.
cd ../android-app
./gradlew :app:assembleDebug
```

`skip-libs/` is gitignored — it's a build artefact regenerated from
the Swift sources. The APK packages the `.aar` files directly via
`debugImplementation(fileTree(...))`.

## Ergonomic shape compared

|                         | Hand-written bridge       | SkipFuse                       |
|-------------------------|---------------------------|--------------------------------|
| LOC for the bridge      | ~1,180                    | ~35 (mostly bootstrap)         |
| LOC per new `@Observable` property | ~30 Swift + ~4 Kotlin | one Swift line + bridge marker |
| `[Story]` access        | `walkStoriesPeer(peer)` per emission | direct field read via JNI |
| Cancellation on suspend | wired                     | not propagated upstream        |
| APK size impact         | ~99 MB debug              | ~99 MB debug (parity)          |
| Bridge tests            | `BridgePerfTest` cold-start regression | none yet — needs reseeding |

## Where the previous bridge lives

Frozen on the `extension-method-bridge-experiment` branch and in
[`docs/historical/`](historical/README.md). Useful as a record of
what we tried; don't try to revive it.
