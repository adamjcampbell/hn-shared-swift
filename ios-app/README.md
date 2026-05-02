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

## Verified

`xcodebuild` for `arm64-apple-ios17.0-simulator` succeeds; the app launches on
the iPhone 17 simulator and renders the cities list with the header card —
visually equivalent to the Android variant (spec §10.7). The Compose-side
behaviours (heart toggle reorders, pull-to-refresh updates header values) are
implemented identically on iOS via `@Observable` + SwiftUI's built-in
observation tracking.
