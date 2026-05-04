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
  `NavigationStack`. Below it, every view takes either an `AppState`
  forwarded whole (when all four fields flow downstream) or narrow
  slices (e.g. `CityRows` stores only `cities` and `favorites`). No
  view below `RootView` references `AppModel`.
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
  per-section skip behaviour. The two former computed properties on
  the inner content view (`searchResults`, `fullList`) were extracted
  into `SearchResults` and `FullCitiesList` structs.
- Each child View stores only the fields its body reads — `CityRows`
  takes `cities`/`favorites`, not the whole `AppState`, so refreshes
  (which only mutate `globalFavoriteCount` / `lastRefreshedAt`) skip
  `CityRows.body` entirely.

`AGENT.md` in the repo root has the same rules in its "Non-obvious
project rules" section.

## Verified

`xcodebuild` for `arm64-apple-ios17.0-simulator` succeeds; the app launches on
the iPhone 17 simulator and renders the cities list with the favorites
summary — visually equivalent to the Android variant (spec §10.7). The
Compose-side behaviours (heart toggle reorders, pull-to-refresh updates
header values) are implemented identically on iOS via `@Observable` +
SwiftUI's built-in observation tracking.
