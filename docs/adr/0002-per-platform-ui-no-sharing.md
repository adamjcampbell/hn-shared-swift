# ADR-0002: Per-platform UI; no UI code sharing

## Status

Accepted (2026-05-02).

## Context

A Swift-on-Android project that already shares the core logic faces an obvious follow-on question: share the UI too? The two plausible paths are:

1. Write SwiftUI once and translate it to Compose. Tools like SkipUI ship a Kotlin reimplementation of the SwiftUI API surface and render SwiftUI bodies through Compose under the hood.
2. Write two UIs — SwiftUI for iOS and Jetpack Compose for Android — both consuming the same shared core.

Translation buys code reuse but introduces an adapter layer between the developer's intent and the platform's native rendering. Anything outside the translator's covered surface — a Material 3 component, a SwiftUI-specific modifier, a platform-specific affordance — hits a gap that either has to be worked around or contributed upstream to the translator. The Android UX quality bar of "looks and feels like Compose" is materially lower if every Compose feature has to round-trip through a SwiftUI-shaped abstraction.

Writing two UIs costs duplicated layout work but lets each platform be fully idiomatic — every native API is reachable without proxy types, every Material 3 / SwiftUI affordance is available, the debug tooling is the platform's own.

For this project the goal is to demonstrate that a Swift `@Observable` model can drive native Android UI as well as it drives SwiftUI. Adopting a UI translation layer would push that demonstration one level removed from "Compose reading a Swift class directly".

## Decision

The UIs are written separately. iOS is SwiftUI; Android is Jetpack Compose. They share nothing visually except the layout intent — there is no shared layout DSL, no translation step, no proxy view types. Both UIs depend on the same Swift `Core` and read the same `@Observable` `Model` ([ADR-0001](0001-observable-model-source-of-truth.md)).

## Consequences

- New visual features land twice: once in SwiftUI, once in Compose. The implementations diverge in idiomatic ways (the iOS list uses `.searchable`; the Android equivalent uses a `SearchBar` composable) and that's the point.
- Every Compose feature is available — `LazyColumn`, `SwipeToDismissBox`, Material 3 theming, `rememberSaveable`, edge-to-edge layout — without indirection.
- The shared core stays small: just `Model`, `Engine`, `Core`, `Message`, `Command`, the story types, and the HN client. Anything UI-shaped lives in the platform target.
- Visual parity between platforms is best-effort and verified by screenshot comparison, not by a single source. Drift between the two implementations is possible; it shows up as the iOS and Android views looking subtly different, which is preferable to both looking subtly wrong because they routed through an adapter.
