# iOS app

The Swift sources for the SwiftUI app live in `AppCoreBridgeExample/`.

The Xcode project (`AppCoreBridgeExample.xcodeproj`) is **generated from
`project.yml`** by [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — it's
gitignored because it's a derived artefact.

## Generate + build

```sh
brew install xcodegen
cd ios-app
xcodegen generate

# Build for an iOS Simulator (pick any modern iPhone with iOS 17+):
xcodebuild \
  -project AppCoreBridgeExample.xcodeproj \
  -scheme AppCoreBridgeExample \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build

# Or open it in Xcode and run:
open AppCoreBridgeExample.xcodeproj
```

## What's wired

- Deployment target: iOS 17 (matches `Package.swift` floor for `AppCore`).
- Local SwiftPM dependency on `../AppCore` via the `AppCore` product only.
  The package's other dep, `swift-java`, is referenced by the `AppCoreAndroid`
  target only and SwiftPM correctly excludes it from iOS resolution.
- Codesigning is disabled (`CODE_SIGNING_ALLOWED=NO`) so simulator builds work
  out of the box. Re-enable for device runs.

## Architecture

Two source files, both in `AppCoreBridgeExample/`:

- **`RootView.swift`** — the view tree. `RootView` owns the singleton
  `AppModel` (as `@State`) and installs `\.dispatch` on the
  `NavigationStack`. `AppState` itself is the `@Observable final
  class`; descendants take it as a parameter and rely on per-property
  tracking for invalidation. Leaf views that already work in terms of
  value-type slices (e.g. `StoryRows` taking `[Story]`, `StoryRow`
  taking `Story`) keep doing so — struct equality is the natural diff
  signal there. No view below `RootView` references `AppModel`.
- **`AppEventDispatch.swift`** — the `\.dispatch` capability action.
  An `Equatable` callable struct mirroring SwiftUI's `DismissAction`:
  child views call `dispatch(.toggleFavorite(id:))` (sync,
  fire-and-forget) or `await dispatch.run(.refresh)` (awaitable, for
  `.refreshable`). The `Equatable` conformance is load-bearing —
  raw closures in `EnvironmentValues` defeat SwiftUI's reflection
  diff and invalidate every descendant on each parent body re-eval.

Performance corollaries reflected in the source:

- Computed `private var foo: some View` properties are *not* used —
  SwiftUI can only diff stored properties on `View` structs, so
  computed properties get inlined into the parent body and lose
  per-section skip behaviour. Each subview is a real `struct … : View`
  so it gets its own diffing checkpoint.
- With `AppState` as `@Observable`, the macro instruments each
  property accessor — a body that reads `state.searchQuery` only
  re-runs when `searchQuery` changes, regardless of how the parent
  passes the reference. There's no benefit to splitting `AppState`
  into per-field parameters; pass `state: AppState` and let SwiftUI
  track per property. Reserve narrow value-type inputs for leaves.
- Two-state surfaces use `.overlay { if cond { … } }`, not top-level
  `if/else`. `SearchResults` is mounted as an overlay over
  `FullCitiesList` whenever `\.isSearching` is true, so the main
  list's scroll position and internal state survive a search
  round-trip (this is Apple's WWDC21 recommendation). The empty state
  inside `SearchResults` is the same pattern, one level down: the
  plain list is always mounted; `ContentUnavailableView.search` is
  overlaid when there are no matches. `.background(.background)` on
  the search overlay occludes the inset-grouped chrome behind it.

`AGENT.md` in the repo root has the same rules in its "Non-obvious
project rules" section.

## Verified

`xcodebuild` for `arm64-apple-ios17.0-simulator` succeeds; the app launches
on the iPhone 17 simulator and renders the Hacker News front page with
header card and search bar — visually equivalent to the Android variant
(spec §10.7). Compose-side behaviours (toggle-read flips strikethrough,
pull-to-refresh updates the timestamp, debounced search) are implemented
identically on iOS via `@Observable` + SwiftUI's built-in observation
tracking. iOS keeps an inline `ProgressView` in the header card because
`.refreshable`'s spinner is gesture-driven only; Android dropped its
inline indicator since `PullToRefreshBox(isRefreshing = …)` is
programmatic and shows for cold-start fetches too.
