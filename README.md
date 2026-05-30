# Hacker News Reader Example

An example of cross-platform `@Observable` ↔ Compose via
[SkipFuse](https://skip.dev): one Swift `@Observable` model drives
native SwiftUI on iOS and native Jetpack Compose on Android. The Swift
core is compiled natively to `.so` for Android and bridged to Kotlin.
Compose reads `@Observable` properties inside `@Composable`s, mutations
recompose, `async` functions become `suspend`, `AsyncStream` becomes
`Flow`.

The app fetches front-page stories from the
[official Firebase API](https://github.com/HackerNews/API), search from
the [Algolia HN API](https://hn.algolia.com/api), and shows a per-story
read indicator. Networking lives in Swift via `URLSession`.

## How Skip is used

Skip's tagline is **One Swift Codebase. Two Native Platforms.** This
approach differs: only the model and engine ship as Swift on both
platforms. The UIs are written per platform: SwiftUI on iOS, Jetpack
Compose on Android.

## Architecture in brief

A single observable `Model` is the source of truth, user inputs flow
in as `Message`s, and one-shot side-effects flow out as `Command`s,
names borrowed from Elm.

Mutations are written in **idiomatic Swift, made concurrency-safe by
an `actor`**. A single `Engine` actor owns every write to `Model`, so
the `@Observable` class itself stays a nonisolated mutable data bag
while race-free access is enforced by Swift 6's region-based isolation.

The `Engine` borrows its host's executor: `MainActor` in production, a
`TestActor` in tests. Reads on the UI thread stay synchronous, the
actor hop only serialises writes, and nothing crosses an isolation
boundary.

## Consuming the `Core`

`Core` is a `@MainActor` struct that exposes the surfaces the UI
consumes while hiding the `Engine` actor. Actors aren't part of the
Swift-to-Kotlin bridge surface.

`makeCore()` runs once per process and returns a `Core` value with
three surfaces:

- `model` — the `@Observable` source of truth.
- `sendMessage` — an `Equatable` capability for dispatching `Message`s.
- `commands` — an `AsyncStream<Command>` of one-shot side-effects.

Both UIs consume the same `Core`.

```swift
// iOS — HackerNewsReaderApp.swift
@main struct HackerNewsReaderApp: App {
    @State private var core = makeCore()
    var body: some Scene { WindowGroup { RootView(core: core) } }
}
```

```kotlin
// Android — App.kt
class App : Application() {
    lateinit var core: Core; private set
    override fun onCreate() {
        super.onCreate()
        ProcessInfo.launch(applicationContext)
        core = makeCore()
    }
}
```

### Reading the `Model`

Descendants pull the `Model` from the environment on iOS, or read
`core.model` directly inside `@Composable`s on Android. Both sides
observe property-level changes; writes go through the synthesised
setter and invalidate readers.

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
LazyColumn { items(model.feedStories.kotlin() as List<StoryRow>) { StoryRowView(it) } }
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
val sendMessage = core.sendMessage

LaunchedEffect(Unit) { sendMessage.send(Message.refresh) }
PullToRefreshBox(onRefresh = { scope.launch { sendMessage.run(Message.refresh) } }) { … }
```

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
// Android — AsyncStream surfaced as a Kotlin Flow via .kotlin().
LaunchedEffect(Unit) {
    core.commands.kotlin().collect { command ->
        when (command) {
            is Command.PresentURLCase -> context.launchCustomTab(command.value)
        }
    }
}
```

### Localized strings

The app's strings come from a single `Localizable.xcstrings` catalog.
A generated `Strings` enum exposes typed accessors that bridge across
SkipFuse, so Compose reads the same source as SwiftUI without a
separate Android string store.

## Why one Model, one Engine

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

`Model` is our data and `Engine` hosts the procedures that act on
it. Two pieces, not a tree of objects split by feature, so there's
no up and down communication between them. Data and procedures are
separate concerns, and the isolation region `Engine` provides keeps
`Model`'s mutations race free. Each `Message`'s handling reads top
to bottom in one place leaning into *Locality of Behaviour*.

`Model` holds both the source of truth and its derivations. The
entity store, the feed and search load state, read tracking, and
the search query are the raw data. `feedStories` and `searchResults`
are derived projections the UI binds to.

Composition is achieved by function, not by type, under the old
adage that *data + procedures = programs*. In this way
`fetch(debounce:body:)` is the shared helper, handling debounce,
task cancellation, and the normalisation of `URLError(.cancelled)`
to `CancellationError` for every fetch path.

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

- `HackerNewsReader/` — SwiftPM package, two targets, one exported
  product (`.library(name: "HackerNewsReader")`).
  - `HackerNews` — API client and entity types: `Client`, `Story`,
    `Page`. Self-contained Hacker News SDK.
  - `HackerNewsReader` — `Model` + `Engine` + the bridged factory
    `makeCore() -> Core`, plus `Message`, `Command`,
    `SendMessageAction`, `StoryRow`, `LoadStatus`, `LoadedStories`,
    `Dependencies` (the `@TaskLocal` `Date` seam), and the bridged
    `Strings` enum generated from `Resources/Localizable.xcstrings`
    by `scripts/generate-strings.swift`. Depends on `HackerNews`;
    Skip transitively packages `HackerNews` into the AAR set.
- `ios-app/` — SwiftUI app generated from `project.yml` by
  [`xcodegen`](https://github.com/yonaskolb/XcodeGen).
- `android-app/` — Gradle project consuming the SkipFuse-exported AARs
  from `skip-libs/`, which is gitignored. A `skipExport` task wired
  into `preBuild` re-runs `skip export` whenever Swift sources change.

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
| Skip CLI | 1.8.14 |
| Kotlin | 2.3.0 — must match SkipFuse's exported AAR metadata |
| Android NDK | 27.x, via Skip CLI's auto-managed install |
| JDK | 21 — Android Studio's bundled JBR works |
| Xcode | 26.0+ |
| iOS deployment target | 17.0 |
| Android `minSdk` | 28 |
