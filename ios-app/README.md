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

## How the model reaches the UI

`HackerNewsReaderApp` calls `makeCore()` once via `@State` and hands
the resulting `Core` to `RootView`. `RootView` installs the
`Model` and the `\.sendMessage` capability into the SwiftUI
environment; descendants read state via `@Environment(Model.self)`
and dispatch messages via `@Environment(\.sendMessage)` —
`sendMessage(.foo)` for fire-and-forget, `await sendMessage.run(.foo)`
for awaitable.

The SwiftUI view-layer rules — per-property `@Observable`
invalidation, the overlay pattern, when to extract a `View` struct —
live in [`AGENTS.md`](../AGENTS.md).
