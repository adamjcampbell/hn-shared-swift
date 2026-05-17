# Cross-platform `@Observable` ↔ Compose, via SkipFuse

A minimal example of one Swift `@Observable` model driving native
SwiftUI on iOS and native Jetpack Compose on Android. The Swift core
is compiled natively to `.so` and bridged to Kotlin by
[SkipFuse](https://skip.dev) — Compose reads `@Observable` properties
directly inside `@Composable`s, mutations recompose, `async` functions
are `suspend`, `AsyncStream` is `Flow`, `[StoryRow]` is a Kotlin
`List`.

The example app is a small Hacker News reader: front-page stories
(via the [official HN Firebase API](https://github.com/HackerNews/API)
for live-ranked ordering), search (via the
[Algolia HN API](https://hn.algolia.com/api) — Firebase has no
search), and a per-story read indicator. Networking lives in Swift
(`URLSession` via conditional `import FoundationNetworking` on
Android); both UIs only render the snapshot.

## How the bridge looks at the call site

Both UIs render the same Swift `AppState` instance:

```swift
// HackerNewsReader/Sources/HackerNewsReader/AppState.swift
// bridged via // SKIP @bridgeMembers
@Observable public final class AppState {
    public var searchQuery: String = ""
    public var feedLoaded: LoadedStories? = nil
    public var feedInitialStatus: LoadStatus = LoadStatus()
    public var feedLoadMoreStatus: LoadStatus = LoadStatus()
    public var feedStories: [StoryRow] { ... }
}
```

```kotlin
// android-app — Compose reads the bridged class directly.
import hacker.news.reader.appState
TextField(value = appState.searchQuery, onValueChange = { appState.searchQuery = it })
LazyColumn { items(appState.feedStories.kotlin() as List<StoryRow>) { StoryRowView(it) } }
```

There is no hand-written JNI glue, no per-property thunk, no
`SwiftState`, no `*OnChange` SAM. SkipFuse generates all of it from
the `// SKIP @bridgeMembers` markers on the Swift sources.

## Layout

- `HackerNewsReader/` — SwiftPM package with two targets bridged to
  Kotlin via the `skipstone` build plugin.
  - `HackerNews` — API client + entity types (`Client`, `Story`,
    `Page`). Self-contained Hacker News SDK; no app-level state.
  - `HackerNewsReader` — reducer + state (`AppCore`, `AppState`,
    `StoryRow`, `LoadStatus`, `LoadedStories`) and the bridged module
    surface in `Core.swift` (module-level `appState`, `commands`,
    `sendEvent`, `sendEventAsync`). Depends on `HackerNews`. Public
    product consumed by iOS; Skip transitively packages `HackerNews`
    into the AAR set.
- `ios-app/` — SwiftUI app generated from `project.yml` via
  [`xcodegen`](https://github.com/yonaskolb/XcodeGen). Imports
  `HackerNewsReader` directly.
- `android-app/` — standard Android Gradle project. Consumes
  `HackerNewsReader-debug.aar` + `HackerNews-debug.aar` + the Skip
  runtime AARs from `android-app/skip-libs/` (gitignored). A
  `skipExport` Gradle task wired into `preBuild` re-runs `skip export`
  whenever Swift sources change, so `./gradlew :app:assembleDebug`
  (or hitting Run in Android Studio) rebuilds the bridge transparently.
- `docs/skip-fuse-adoption.md` — why we adopted SkipFuse and the
  gotchas we hit during the migration.
- `docs/historical/` — design docs for the previous hand-written JNI
  bridge. Frozen — don't act on these.

## Verified

| Surface | Tested how | Status |
|---|---|---|
| `HackerNewsReader` SwiftPM package | `cd HackerNewsReader && swift test --disable-sandbox`, 38/38 pass | ✅ |
| iOS app | `xcodebuild` for iPhone 17 / iOS 26.4 simulator | ✅ |
| Android: build | `./gradlew :app:assembleDebug` produces a 99 MB debug APK | ✅ |
| Android: runtime | App launches on `Medium_Phone_API_36.1` AVD, fetches HN stories, search debounces and updates | ✅ |

## Quick start

iOS: see [`ios-app/README.md`](ios-app/README.md).
Android: see [`android-app/README.md`](android-app/README.md).
The rationale for adopting SkipFuse and the gotchas during the
migration are in [`docs/skip-fuse-adoption.md`](docs/skip-fuse-adoption.md).

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
