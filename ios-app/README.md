# iOS app

SwiftUI app that depends on the local `HackerNewsReader` SwiftPM
package. The Xcode project (`HackerNewsReader.xcodeproj`) is
**generated** from `project.yml` by
[`xcodegen`](https://github.com/yonaskolb/XcodeGen), and is gitignored.

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

`-skipPackagePluginValidation` is required because SwiftPM resolution
pulls in SkipFuse's `skipstone` plugin (the same plugin used for the
Android build); Xcode prompts for plugin approval otherwise.

## What's wired

- Deployment target: iOS 17.
- Local SwiftPM dependency on `../HackerNewsReader`.
- Codesigning disabled (`CODE_SIGNING_ALLOWED=NO`) so simulator builds
  work out of the box. Re-enable for device runs.

## How state reaches the UI

`HackerNewsReaderApp` calls `makeAppCore()` once via `@State` and hands
the resulting `AppCore` handle to `RootView`. `RootView` installs
`AppState` and the `\.sendEvent` capability action into the SwiftUI
environment; descendants read state via `@Environment(AppState.self)`
and call events via `@Environment(\.sendEvent)` — `sendEvent(.foo)`
for fire-and-forget, `await sendEvent.run(.foo)` for awaitable.

The SwiftUI view-layer rules (per-property `@Observable` invalidation,
the overlay pattern, when to extract a `struct: View`) live in
[`AGENT.md`](../AGENT.md).
