# Hacker News Reader Example

An example of cross-platform `@Observable` ↔ Compose via
[SkipFuse](https://skip.dev): one Swift `@Observable` model drives
native SwiftUI on iOS and native Jetpack Compose on Android. The Swift
core is compiled natively to `.so` for Android and bridged to Kotlin —
Compose reads `@Observable` properties inside `@Composable`s, mutations
recompose, `async` functions become `suspend`, `AsyncStream` becomes
`Flow`.

The app fetches front-page stories from the
[official Firebase API](https://github.com/HackerNews/API), search from
the [Algolia HN API](https://hn.algolia.com/api) (Firebase has no
search endpoint), and shows a per-story read indicator. Networking
lives in Swift (`URLSession`); both UIs only render the snapshot.

## The bridge at the call site

`makeAppCore()` is called once per process and returns an `AppCore`
handle with three parts: `state` (the `@Observable` bag), `sendEvent`
(an Equatable capability for dispatching `AppEvent`s), and `commands`
(an `AsyncStream<AppCommand>` of one-shot side-effects). Both UIs
consume the same handle.

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
    lateinit var core: AppCore; private set
    override fun onCreate() {
        super.onCreate()
        ProcessInfo.launch(applicationContext)
        core = makeAppCore()
    }
}
```

### `state` — observed reads and two-way bindings

```swift
// iOS — descendants pull AppState from the environment; @Bindable
// + key-path Binding for two-way writes.
@Environment(AppState.self) private var state

var body: some View {
    @Bindable var state = state
    List(state.feedStories) { StoryRowView(story: $0) }
        .searchable(text: $state.searchQuery, prompt: "Search Hacker News")
}
```

```kotlin
// Android — Compose reads @Observable properties directly; writes go
// through the synthesized setter and invalidate readers.
val state = core.state
TextField(
    value = state.searchQuery,
    onValueChange = { state.searchQuery = it },
)
LazyColumn { items(state.feedStories.kotlin() as List<StoryRow>) { StoryRowView(it) } }
```

### `sendEvent` — fire-and-forget + awaitable

```swift
// iOS — sendEvent(.foo) is fire-and-forget; await sendEvent.run(.foo)
// is awaitable (.refreshable, one-shot .task).
@Environment(\.sendEvent) private var sendEvent

.refreshable { await sendEvent.run(.refresh) }
Button("Mark read") { sendEvent(.toggleRead(id: story.id)) }
```

```kotlin
// Android — same shape, .send(...) and suspend .run(...).
val sendEvent = core.sendEvent

LaunchedEffect(Unit) { sendEvent.send(AppEvent.refresh) }
PullToRefreshBox(onRefresh = { scope.launch { sendEvent.run(AppEvent.refresh) } }) { … }
```

### `commands` — one-shot side-effects from core to UI

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
            is AppCommand.PresentURLCase -> context.launchCustomTab(command.value)
        }
    }
}
```

No hand-written JNI, no per-property thunk, no `*OnChange` SAM —
SkipFuse generates all of it from the `// SKIP @bridgeMembers` marker
on `AppState`.

## Layout

- `HackerNewsReader/` — SwiftPM package, two targets, one exported
  product (`.library(name: "HackerNewsReader")`).
  - `HackerNews` — API client + entity types (`Client`, `Story`,
    `Page`). Self-contained Hacker News SDK.
  - `HackerNewsReader` — reducer + state (`AppCore`, `AppEngine`,
    `AppState`, `StoryRow`, `LoadStatus`, `LoadedStories`) plus the
    bridged factory `makeAppCore() -> AppCore`. Depends on
    `HackerNews`; Skip transitively packages `HackerNews` into the AAR
    set.
- `ios-app/` — SwiftUI app generated from `project.yml` by
  [`xcodegen`](https://github.com/yonaskolb/XcodeGen).
- `android-app/` — Gradle project consuming the SkipFuse-exported AARs
  from `skip-libs/` (gitignored). A `skipExport` task wired into
  `preBuild` re-runs `skip export` whenever Swift sources change.
- `docs/skip-fuse-adoption.md` — why we adopted SkipFuse and the gotchas
  hit during the migration.
- `docs/historical/` — design docs for the previous hand-written JNI
  bridge. Frozen; don't act on them.

Architecture, concurrency rules, and the SwiftUI view-layer conventions
are in [`AGENT.md`](AGENT.md).

## Quick start

- iOS — see [`ios-app/README.md`](ios-app/README.md).
- Android — see [`android-app/README.md`](android-app/README.md).
- Swift unit tests — `cd HackerNewsReader && swift test --disable-sandbox`.
- Migration story — [`docs/skip-fuse-adoption.md`](docs/skip-fuse-adoption.md).

## Toolchain

| Component | Version |
|---|---|
| Swift | 6.3.1 |
| Skip CLI | 1.8.14 |
| Kotlin | 2.3.0 (must match SkipFuse's exported AAR metadata) |
| Android NDK | 27.x (via Skip CLI's auto-managed install) |
| JDK | 21 (Android Studio's bundled JBR works) |
| Xcode | 26.0+ |
| iOS deployment target | 17.0 |
| Android `minSdk` | 28 |
