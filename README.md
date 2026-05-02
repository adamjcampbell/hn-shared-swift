# Cross-platform `@Observable` ↔ Compose Bridge

A minimal example of a single Swift `@Observable` model shared between an iOS
SwiftUI app and an Android Jetpack Compose app, **without Skip**, on the
official Swift Android SDK.

See [`swift-observable-compose-bridge-spec.md`](swift-observable-compose-bridge-spec.md)
for the full implementation spec, design rationale, and references.

## Layout

- `AppCore/` — SwiftPM package with two targets: cross-platform `AppCore`
  (consumed by iOS) and `AppCoreAndroid` (the JNI-facing bridge, Android only).
- `ios-app/` — SwiftUI app that depends on the `AppCore` product.
- `android-app/` — Gradle project that builds `AppCoreAndroid` for Android via
  the Swift Android SDK and consumes it through `swift-java jextract --mode=jni`.

## Status

The Swift sources in `AppCore/Sources/` and the Kotlin sources under
`android-app/app/` are implemented as the spec dictates. The
`xcodeproj`, the `jextract`-generated Java surface, and the precise Gradle
task wiring are intentionally left for the implementer to produce on the
target host (see spec §6.1 and §12).
