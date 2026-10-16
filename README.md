# Hacker News Reader Example

An example of cross-platform `@Observable` ↔ Compose via
[official Swift–Java](https://github.com/swiftlang/swift-java): one Swift `@Observable` model drives
native SwiftUI on iOS and native Jetpack Compose on Android. The Swift
core is compiled natively to `.so` for Android and bridged to Kotlin.
Generated accessors connect Swift Observation invalidations to Compose.
Kotlin adapters expose cancellable suspend operations and a command `Flow`.
The migration is validated locally on iOS Simulator and an arm64 Android emulator;
see [ADR-0022](docs/adr/0022-official-swift-java-bridge.md) for checks and limits.

The app fetches front-page stories from the
[official Firebase API](https://github.com/HackerNews/API), search from
the [Algolia HN API](https://hn.algolia.com/api), and shows a per-story
read indicator. Shared Swift owns URL construction and JSON decoding;
`PlatformSupport` uses `URLSession` on Apple platforms and OkHttp via JNI
on Android, through an async `@Sendable (URL) -> HTTPResponse` GET seam.

## Shared core, native UIs

Only the model and its mutation logic ship as Swift
on both platforms. The UIs are written per platform: SwiftUI on iOS,
Jetpack Compose on Android.

## Architecture in brief

A single observable `Model` is the source of truth, user inputs flow
in as `Message`s, and one-shot side-effects flow out as `Command`s,
names borrowed from Elm.

Mutations are written in **idiomatic Swift, made concurrency-safe by
region-based isolation**. The mutation logic is a set of free functions,
not an object: `makeCore` threads its caller's actor through `#isolation`,
so the host actor owns every write to `Model`. The `@Observable` class
itself stays a nonisolated mutable data bag, and Swift 6's region-based
isolation keeps the non-`Sendable` `Model` from ever leaving that region.

The host actor is `MainActor` in production (via `makeAppCore()`) and a
`TestActor` in tests. Reads on the UI thread stay synchronous, only writes
serialise onto the host actor, and nothing crosses an isolation boundary.

## Consuming the `Core`

Swift `Core` is a plain struct holding the surfaces the UI consumes.
Android's Kotlin `Core` owns an official Java `AndroidReader` peer that
adapts the model, message operations and command stream; Swift's internal
send entry and teardown hook are not exported directly.

`makeAppCore()` runs once per process on `MainActor` and returns a
`Core`. The UI reads two surfaces directly:

- `model` — the `@Observable` source of truth.
- `commands` — an `AsyncStream<Command>` of one-shot side-effects.

For dispatching `Message`s, the send capability is composed at the app
boundary from the handle: `SendMessageAction(core)` wraps `Core`'s
internal send entry in an `Equatable` action. Android uses a Kotlin action
over native task handles for the same shared core.

```swift
// iOS — HackerNewsReaderApp.swift
@main struct HackerNewsReaderApp: App {
    @State private var core = makeAppCore()
    var body: some Scene { WindowGroup { RootView(core: core) } }
}
```

```kotlin
// Android — App.kt
class App : Application() {
    lateinit var core: Core; private set
    override fun onCreate() {
        super.onCreate()
        System.loadLibrary("SwiftJava")
        System.loadLibrary("HackerNewsReader")
        System.loadLibrary("MainLooper")
        PlatformServices.setupMainLooper()
        core = Core()
    }
}
```

### Reading the `Model`

Descendants pull the `Model` from the environment on iOS, or read
`core.model` directly inside `@Composable`s on Android. Both sides
observe property-level changes; writes go through the Swift setter and
invalidate readers. Kotlin stores revision counters and immutable value
copies, not authoritative mutable app state. Getters read the latest Swift
state, not snapshot-versioned state associated with a Compose revision.
Native values are copied within confined arenas and disposed; `Date`
projects to epoch-seconds `Double`.

```swift
// iOS — @Bindable + $model.foo for two-way writes.
@Environment(Model.self) private var model

var body: some View {
    @Bindable var model = model
    List(model.feedStories) { StoryRowView(story: $0) }
        .searchable(text: $model.searchQuery, prompt: "Search Hacker News")
}
```

```kotlin
// Android — Compose reads @Observable properties directly.
val model = core.model
TextField(
    value = model.searchQuery,
    onValueChange = { model.searchQuery = it },
)
LazyColumn { items(model.feedStories) { StoryRowView(it) } }
```

### Row projections

`Model.feedStories` and `Model.searchResults` vend `[StoryRow]`, a
value type with the row's display strings baked in. Both platforms
render row properties directly, so neither has to format the row
itself.

### Sending a `Message`

`SendMessageAction` mirrors SwiftUI's `DismissAction` ergonomic:
`callAsFunction` for fire-and-forget, `run` for awaitable.

```swift
// iOS — sendMessage(.foo) fire-and-forget; await sendMessage.run(.foo)
// from .refreshable / one-shot .task.
@Environment(\.sendMessage) private var sendMessage

.refreshable { await sendMessage.run(.refresh) }
Button("Mark read") { sendMessage(.toggleRead(id: story.id)) }
```

```kotlin
// Android — same shape: .send(...) and suspend .run(...).
val sendMessage = remember(core) { SendMessageAction(core) }

LaunchedEffect(Unit) { sendMessage.send(Message.refresh) }
PullToRefreshBox(onRefresh = { scope.launch { sendMessage.run(Message.refresh) } }) { … }
```

The synchronous JNI thunk copies each `Message` before Swift suspends.
`suspendCancellableCoroutine` cancels its native task handle, propagating
cancellation through the Swift core to the underlying fetch. No raw-peer
async future path is used.

### Receiving `Command`s

One-shot imperatives from the core to the UI — typically platform
presentations whose lifetime belongs to SwiftUI or Compose, not to
the `Model`.

On iOS this could be tracked as a `presentedURL: String?` on `Model`;
the `Command` channel keeps the same shape on both platforms.

```swift
// iOS — long-lived consumer in .task; the sheet binding lives on the
// view, so user-driven dismissal doesn't touch the core.
.task {
    for await command in core.commands {
        switch command {
        case .presentURL(let url): presented = IdentifiedURL(url)
        }
    }
}
```

```kotlin
// Android — typed official Java peers adapted to a Kotlin Flow.
LaunchedEffect(Unit) {
    core.commands.collect { command ->
        when (command) {
            is Command.PresentURL -> context.launchCustomTab(command.value)
        }
    }
}
```

The native command pump survives Activity collector cancellation and
recollection until `Core.close()`. Only one consumer is supported; commands
without a subscriber are dropped. Core explicitly closes observations,
tasks and native resources, but production uses Application lifetime.

### Localized strings

The app's strings come from a single `Localizable.xcstrings` catalog.
A generated `Strings` enum exposes typed accessors that bridge across
the official Java peers, so Compose reads the same source as SwiftUI without a
separate Android string store.
Apple uses its compiled resource bundle; Android uses generated catalog
tables selected by platform language preferences. PlatformSupport also
provides native time-of-day formatting.

## Why one Model, free functions

Common app architectures often leave me feeling unsatisfied. It is
standard procedure to separate screens, features, etc, into
distinct objects. When child objects need to communicate with parent
objects or screens this often results in unnecessary orchestration.
Callbacks, handlers, coordinators and the like. Separating by
feature or screen also obscures shared semantics across them and
can lead to siloed duplication.

In pursuit of a grounded approach to solving this dissatisfaction
I found myself gravitating to talks by systems and games
programmers who model their programs in data oriented ways. This
architecture attempts to capitalise on the fact that both SwiftUI
and Jetpack Compose allow us to model our application as pure state
that is observed. This allows a natural fit for modelling behaviour
as procedures that act on data. So:

`Model` is the data and free functions are the procedures that act on
it. Two pieces, not a tree of objects split by feature, so there's
no up and down communication between them. Data and procedures are
separate concerns, and the host actor's isolation region, threaded
through `#isolation`, keeps `Model`'s mutations race free. Each
`Message`'s handling reads top to bottom in one place leaning into
*Locality of Behaviour*.

`Model` holds both the source of truth and its derivations. The
entity store, the feed and search load state, read tracking, and
the search query are the raw data. `feedStories` and `searchResults`
are derived projections the UI binds to.

Composition is achieved by function, not by type, under the old
adage that *data + procedures = programs*. In this way
`fetch(debounce:body:)` is the shared helper for debounce and task
cancellation. PlatformSupport normalizes transport cancellation to
`CancellationError`; on Android it also cancels the underlying OkHttp Call.

*Semantic Compression* makes the same case for the fetch paths.
The feed and search fetch paths look similar but are different
semantically: each writes to different `Model` fields, cancels a
different prior task, and the search paths thread `searchQuery`
through. A shared type would just be forced to fit across different
semantics.

This is a small app written by one person. A lot of the granular
vertical slicing I complained about above exists because large
teams need clear ownership boundaries to coordinate, not because
the code itself demands it. The structure here hasn't been tested
at that scale.

That said, teams are often larger and more numerous than they need
to be, driven by organisational needs rather than technical ones.
Outside that overhead, app complexity could be much lower.

### References

**Cited above**

- [*Locality of Behaviour*](https://htmx.org/essays/locality-of-behaviour/), Carson Gross. A code unit's behaviour should be obvious from that unit alone.
- [*Semantic Compression*](https://caseymuratori.com/blog_0015), Casey Muratori. Treat code like a compression problem; keep same-meaning things in one place.
- [Odin](https://odin-lang.org/)'s design philosophy: programs transform data; code expresses the algorithms. See the [Odin FAQ](https://odin-lang.org/docs/faq/) and the creator's [Wookash Podcast appearance](https://creators.spotify.com/pod/profile/lukasz-sciga/episodes/Odin-creator-Ginger-Bill-on-his-programming-language-and-state-of-software-e2sd9un).

**Sources of inspiration**

- [*AHA Programming*](https://kentcdodds.com/blog/aha-programming), Kent C. Dodds. *Avoid Hasty Abstractions*; wait for the abstraction to make itself obvious.
- [*File Pilot: Inside the Engine*](https://www.youtube.com/watch?v=bUOOaXf9qIM), Vjekoslav Krajačić, BSC 2025. A 2 MB Windows file manager shipped from deliberately few files with no per feature code splits.
- [*Algorithms + Data Structures = Programs*](https://en.wikipedia.org/wiki/Algorithms_%2B_Data_Structures_%3D_Programs), Niklaus Wirth (1976).
- [*Inlined Code*](https://cbarrete.com/carmack.html), John Carmack (2007/2014 archive). Inline single-callsite functions; avoid medium-sized helpers.
- [*Go at Google: Language Design in the Service of Software Engineering*](https://go.dev/talks/2012/splash.article), Rob Pike, SPLASH 2012. Composition of independently executing functions over otherwise procedural code.
- [*Data-Oriented Design and C++*](https://www.youtube.com/watch?v=rX0ItVEVjHc), Mike Acton, CppCon 2014. The transformation of data is the program's purpose; design around the data.
- [*State Management: Large Arrays of Things*](https://www.youtube.com/watch?v=L6flrupW3W0), Anton Mikhailov on the Wookash Podcast. State as plain arrays acted on by procedures.
- [*Upstream and Downstream*](https://www.dgtlgrove.com/p/upstream-and-downstream), Ryan Fleury. State lives upstream; downstream reads the bag.
- [*Pass data backward more elegantly without using delegation*](https://clean-swift.com/pass-data-backward-more-elegantly-without-using-delegation/), Clean Swift. Suggests fixing N delegates with closure passing instead of the root cause; an example from the community of the issue this project avoids.
- [*Data Essentials in SwiftUI*](https://developer.apple.com/videos/play/wwdc2020/10040/), Apple WWDC20. Views as a function of state.
- [*Conway's Law*](https://martinfowler.com/bliki/ConwaysLaw.html), Martin Fowler. Organisations design systems shaped by their communication structures; granular vertical slicing is largely a result of separated team responsibility rather than technical need.

## Layout

- `HackerNewsReader/` — SwiftPM package, three library targets, one exported
  product (`.library(name: "HackerNewsReader")`).
  - `HackerNews` — API client and entity types: `Client`, `Story`,
    `Page`. Self-contained Hacker News SDK.
  - `HackerNewsReader` — `Model` plus the free-function core (`makeCore`
    and the `makeAppCore() -> Core` production entry behind AndroidReader), plus
    `Message`, `Command`, `SendMessageAction`, `StoryRow`, `LoadStatus`,
    `LoadedStories`, `Dependencies` (the ambient `@TaskLocal` for
    `date` / `client` / `clock`), and the bridged `Strings` enum
    generated from `Resources/Localizable.xcstrings` by
    `scripts/generate-strings.swift`. Depends on `HackerNews` and
    `PlatformSupport`.
  - `PlatformSupport` — HTTP bytes/status, language preferences, and
    time formatting; Apple Foundation or Android FoundationEssentials + JNI.
- `ios-app/` — SwiftUI app generated from `project.yml` by
  [`xcodegen`](https://github.com/yonaskolb/XcodeGen).
- `android-app/` — Gradle project whose `preBuild` runs `buildSwift`
  (`runtime/build.py`) when its declared inputs change. It consumes
  generated Java peers, Kotlin model adapters, a `SwiftJava.jar`, and native
  libraries from `build/swift/`, not exported native AARs.

`scripts/generate-android.swift` uses SwiftParser to discover public `Model`
fields and generate MainActor-checked accessors, Observation subscriptions,
and value projections. Official `swift-java jextract --mode jni` then emits
synchronous JNI thunks and Java peers. App, Observation and core code use
Swift 6; only generated JNI thunks use Swift 5 mode. No Skip CLI, dependencies,
patches, old SwiftJNI or kotlin-reflect are needed. See
[ADR-0022](docs/adr/0022-official-swift-java-bridge.md).

The Foundation-light runtime preserves Observation, MainActor and TaskLocal
contracts. Its Android UI Looper integration uses private libdispatch SPI;
toolchain upgrades require device tests. See
[ADR-0021](docs/adr/0021-foundation-light-platform-services.md) and the
[runtime notes](android-app/runtime/README.md). The arm64 R8 APK measures
9.85 MB versus 13.49 MB for the saved Foundation-light Skip APK, both signed
with the same local key. Packaged
native code is slightly larger (19.78 MB versus 19.42 MB); this migration
removes Skip dependencies, not the Swift runtime. Full measurement details
and local validation are in ADR-0022.

Architecture, concurrency rules, and the SwiftUI view-layer
conventions are in [`AGENTS.md`](AGENTS.md).

## Quick start

- iOS — see [`ios-app/README.md`](ios-app/README.md).
- Android — see [`android-app/README.md`](android-app/README.md).
- Swift unit tests — `cd HackerNewsReader && swift test`.

## Toolchain

| Component | Version |
|---|---|
| Swift | 6.3.1 |
| swift-java | `301e3da710ede7af93e798f1ce1c7950715a5748` |
| swift-java-jni-core | `b440a0be98381550cf189c903782e817619ffa05` (lockfile) |
| Swift Android SDK | 6.3.1-RELEASE (pinned runtime compatibility boundary) |
| Android build host | macOS only in the current script |
| Kotlin | 2.3.0 |
| Android NDK | 27.3.13750724 |
| JDK | 21 — Android Studio's bundled JBR works |
| Xcode | 26.0+ |
| iOS deployment target | 17.0 |
| Android `minSdk` | 28 |
