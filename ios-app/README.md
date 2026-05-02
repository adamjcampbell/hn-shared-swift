# iOS app

The Swift sources for the SwiftUI app live in `AppCoreBridgeExample/`.

The Xcode project (`AppCoreBridgeExample.xcodeproj`) is **not checked in** — it
is generated locally because it is a binary/derived artefact. To set it up:

1. Open Xcode → File → New → Project → iOS App.
2. Name: `AppCoreBridgeExample`. Interface: SwiftUI. Language: Swift.
3. Replace the generated `App.swift` and `ContentView.swift` with the files in
   this directory.
4. File → Add Package Dependencies → Add Local… → select `../AppCore`.
5. Add the `AppCore` library to the app target.
6. Set the deployment target to iOS 17.

The app target depends only on the `AppCore` product, never on
`AppCoreAndroid` (which would fail to build on iOS thanks to the `#error`
guard in `Platform.swift`).
