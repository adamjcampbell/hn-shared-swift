# iOS app

The Swift sources for the SwiftUI app live in `HackerNewsReader/`.
The Xcode project (`HackerNewsReader.xcodeproj`) is **generated from
`project.yml`** by [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — it's
gitignored because it's a derived artefact.

## Generate + build

```sh
brew install xcodegen
cd ios-app
xcodegen generate

xcodebuild \
  -project HackerNewsReader.xcodeproj \
  -scheme HackerNewsReader \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation \
  build
```

`-skipPackagePluginValidation` is needed because SwiftPM resolution pulls in
SkipFuse's `skipstone` plugin (the same plugin that generates the Kotlin
bridge for Android); Xcode prompts for plugin approval otherwise.

## What's wired

- Deployment target: iOS 17 (matches `Package.swift` floor for `HackerNewsReader`).
- Local SwiftPM dependency on `../HackerNewsReader`. The package now pulls in
  `skip`, `skip-fuse`, and `skip-model` for the Android bridging plugin —
  these resolve cleanly on iOS too (the plugin is a no-op there).
- Codesigning is disabled (`CODE_SIGNING_ALLOWED=NO`) so simulator builds
  work out of the box. Re-enable for device runs.

## Architecture

Source files in `HackerNewsReader/`:

- **`HackerNewsReaderApp.swift`** — the `@main` SwiftUI `App` struct.
  Wraps `RootView` in a `WindowGroup`.
- **`RootView.swift`** — the view tree. Descendants read the module-
  level `appState` directly from `HackerNewsReader` and call the
  bridged `sendEvent(_:)` (sync, fire-and-forget) or
  `await sendEventAsync(_:)` (awaitable, for `.refreshable`). `AppState`
  is the `@Observable final class`; descendants take it as a parameter
  and rely on per-property tracking for invalidation.
- **`SafariView.swift`** — `SFSafariViewController` wrapper for the
  story-detail sheet.

Performance corollaries reflected in the source:

- Computed `private var foo: some View` properties are *not* used —
  SwiftUI can only diff stored properties on `View` structs, so
  computed properties get inlined into the parent body and lose
  per-section skip behaviour. Each subview is a real `struct … : View`.
- With `AppState` as `@Observable`, the macro instruments each property
  accessor — a body that reads `state.searchQuery` only re-runs when
  `searchQuery` changes. Pass `state: AppState` and let SwiftUI track
  per property; reserve narrow value-type inputs for leaves.
- Two-state surfaces use `.overlay { if cond { … } }`, not top-level
  `if/else`, so the underlying view's identity, scroll position, and
  internal state survive the alternate state. `.background(.background)`
  occludes when the overlay needs to fully cover.

The same rules are documented in `AGENT.md`'s iOS view-layer section.

## Verified

`xcodebuild` for `arm64-apple-ios17.0-simulator` succeeds; the app
launches on the iPhone 17 simulator and renders the Hacker News front
page with header card and search bar — visually equivalent to the
Android variant.
