# Cross-platform `@Observable` ↔ Compose, via SkipFuse

A reference example: one Swift `@Observable` model drives native SwiftUI
on iOS and native Jetpack Compose on Android. The Swift core is compiled
natively to `.so` for Android and bridged to Kotlin by
[SkipFuse](https://skip.dev) — Compose reads `@Observable` properties
inside `@Composable`s, mutations recompose, `async` functions become
`suspend`, `AsyncStream` becomes `Flow`. The demo app is a small Hacker
News reader: front-page stories (via the
[official Firebase API](https://github.com/HackerNews/API)), search (via
the [Algolia HN API](https://hn.algolia.com/api) — Firebase has no
search endpoint), and a per-story read indicator. Networking lives in
Swift (`URLSession`); both UIs only render the snapshot.

## The bridge at the call site

Both UIs render the same Swift `AppState` instance:

```swift
// HackerNewsReader/Sources/HackerNewsReader/AppState.swift
@Observable public final class AppState {     // // SKIP @bridgeMembers
    public var searchQuery: String = ""
    public var feedLoaded: LoadedStories? = nil
    public var feedInitialStatus: LoadStatus = LoadStatus()
    public var feedStories: [StoryRow] { ... }
}
```

```kotlin
// android-app — App.onCreate() calls makeAppCore() once.
@Composable fun StoryScreen(core: AppCoreHandle) {
    val state = core.state
    TextField(value = state.searchQuery, onValueChange = { state.searchQuery = it })
    LazyColumn { items(state.feedStories.kotlin() as List<StoryRow>) { StoryRowView(it) } }
}
```

No hand-written JNI, no per-property thunk, no `*OnChange` SAM —
SkipFuse generates all of it from the `// SKIP @bridgeMembers` marker.

## Layout

- `HackerNewsReader/` — SwiftPM package, two targets, one exported
  product (`.library(name: "HackerNewsReader")`).
  - `HackerNews` — API client + entity types (`Client`, `Story`,
    `Page`). Self-contained Hacker News SDK.
  - `HackerNewsReader` — reducer + state (`AppCore`, `AppState`,
    `StoryRow`, `LoadStatus`, `LoadedStories`) plus the bridged
    factory `makeAppCore() -> AppCoreHandle`. Depends on `HackerNews`;
    Skip transitively packages `HackerNews` into the AAR set.
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
