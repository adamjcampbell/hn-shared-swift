# ADR-0005: Strict Swift 6 concurrency + `NonisolatedNonsendingByDefault` (SE-0461)

## Status

Accepted (2026-05-02).

## Context

The shared core runs in two different isolation contexts. On iOS, SwiftUI views are `@MainActor`; reads and mutations happen on `MainActor`. On Android, the bridge owns its own actor (originally a hand-written one, later subsumed by [ADR-0014](0014-mainactor-both-platforms.md) and [ADR-0015](0015-engine-borrows-host-executor.md)); reads and mutations happen on that actor's executor. A non-`Sendable` `Model` reference is accessed from both isolation regions at different times, and the Swift compiler has to verify that no concurrent access slips through.

Swift 6 offers strict concurrency checking. The mode is opt-in via `swiftLanguageMode(.v6)` plus upcoming-feature flags. The relevant flag for cross-platform code is `NonisolatedNonsendingByDefault` (SE-0461): without it, an unannotated `async` function is implicitly `@concurrent` and hops to a generic executor, forcing callers to deal with `Sendable` checking on every parameter. With it, an unannotated `async` function runs on the caller's actor — so `await model.refresh()` from a SwiftUI view runs on `MainActor`, the same call from inside the Android bridge actor runs on that actor's executor, and the model carries no isolation annotation at all.

The alternative, accepting weaker concurrency checking or sprinkling `@unchecked Sendable` and `nonisolated(unsafe)` to silence the compiler, would let bugs through. Real ones: a method that looks synchronous on one platform secretly hops to a different executor and races with a UI thread reader.

## Decision

Both Swift targets enable strict concurrency. The package manifest sets:

```swift
.swiftLanguageMode(.v6),
.enableUpcomingFeature("NonisolatedNonsendingByDefault"),   // SE-0461
.enableUpcomingFeature("InferIsolatedConformances"),         // SE-0470
```

The acceptance criterion is that the core target carries essentially no `@unchecked` or `nonisolated(unsafe)` annotations. Any region-isolation transfer that the compiler can't prove automatically must be made explicit via SE-0414 region isolation or SE-0430 `sending`. The single permitted exception is one `nonisolated(unsafe)` rebind at the `makeCore` boundary, reading the non-`Sendable` `Model` out of the `Engine` actor's isolation region into the `@MainActor` `Core`. It is one binding, one boundary, with the reason documented at the use site.

## Consequences

- The compiler verifies concurrency correctness across actor boundaries, including the boundary between Kotlin-driven JNI entry points and the Swift core.
- An async function with no isolation annotation runs on the caller's actor. `Model.refresh()` looks the same from iOS and from Android even though "the caller's actor" is different on each.
- Adopting strict mode is friction up-front: closures passed to `Task` need `@Sendable`, captures need to be `Sendable`, regions need to be reasoned about. The friction is worth it because the alternative, silent races, is much worse and much harder to find.
- The "near-zero escape hatches in core" target is achievable but not free. Some patterns (notably the cancel-and-replace search task, see [ADR-0015](0015-engine-borrows-host-executor.md)) required deliberate design to fit the compiler's region-isolation model. The one exception is a single `nonisolated(unsafe)` rebind at a single boundary, so the discipline of "the compiler verifies everything else" is preserved.
- `InferIsolatedConformances` (SE-0470) is also enabled — it stops conformances from being inferred as `@MainActor` when the bearer type is. This matters where capability types (`SendMessageAction`) need a nonisolated `Equatable` conformance even though their owners are `@MainActor`.
