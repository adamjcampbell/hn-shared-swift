# ADR-0015: `Engine` actor borrows host executor via `isolation: any Actor` (SE-0392)

## Status

Accepted (2026-05-13).

## Context

The `Engine` actor is the sole writer of `Model` (see [ADR-0016](0016-engine-actor-flat-model.md)). It needs an actor isolation domain for the standard reasons — to serialise mutations, to satisfy region isolation for the non-`Sendable` `Model` reference, and to give the compiler something to check `await` boundaries against.

Two questions follow: *whose* executor does `Engine` use, and how does that executor get plumbed in?

In production the answer is straightforward: `Engine` should run on `MainActor` ([ADR-0014](0014-mainactor-both-platforms.md)) so that `await engine.sendMessage(...)` from a SwiftUI view body or a Compose `@Composable` is a virtual hop with no real thread switch. Marking `Engine` `@MainActor` would do this, but it would also force every test to run on `MainActor`, serialise the test suite, and tie test execution to the UI thread.

For tests the answer needs to be different. Each test wants its own isolation domain so the suite can parallelise across test instances. A bespoke `TestActor` backed by a `DispatchSerialQueue` gives the test a serial executor whose execution is observable (the test can drain pending jobs deterministically via `runPending()`). The test suite then runs N actors in parallel, one per test, with no shared state.

The bridge between "production wants `MainActor`'s executor" and "tests want their own executor" is SE-0392 (Custom Executors) plus the SE-0420 isolation-parameter pattern. An actor with `nonisolated var unownedExecutor: UnownedSerialExecutor { ... }` can return any executor; passing an `isolation: any Actor` parameter to its init lets the caller decide which.

## Decision

`Engine` is a `final actor` that borrows its executor from an `isolation: any Actor` initializer parameter:

```swift
final actor Engine {
    nonisolated let unownedExecutor: UnownedSerialExecutor
    init(model: Model, ..., isolation: any Actor) {
        self.unownedExecutor = isolation.unownedExecutor
        // ...
    }
}
```

Production constructs `Engine` with `MainActor.shared` as the isolation — `Engine`'s executor *is* `MainActor`'s, so `await engine.sendMessage(...)` from `MainActor`-isolated code is a virtual hop.

Tests construct `Engine` via a `withEngine { engine in ... }` fixture that passes a `TestActor`. `TestActor` installs a `DispatchSerialQueue` as its `unownedExecutor`. Each test gets its own actor, its own queue, its own deterministic drain helper (`engine.testActor.runPending()`).

A `nonisolated(unsafe)` rebind is used at one point to hand the non-`Sendable` `Model` into `Engine`'s init under region isolation (SE-0414). The rebind is scoped to `makeCore` and documented in the code that owns it; no other use of `nonisolated(unsafe)` exists in the core target ([ADR-0005](0005-strict-swift6-concurrency.md)).

## Consequences

- `Engine` is a real `actor` — the compiler enforces single-threaded mutation, the type system carries actor isolation through every call.
- Production and tests share the same `Engine` source code. There is no `EngineProtocol`, no `MockEngine`, no test-only subclass. The test's `TestActor` is the *only* test-side seam.
- Test parallelisation works: 32 tests run on 32 `TestActor` instances concurrently. No `Task.megaYield()` retries, no `withMainSerialExecutor` wrappers.
- `await engine.sendMessage(...)` from `MainActor`-isolated SwiftUI code is virtually free in production — same executor, no thread switch. From tests it's a real hop onto the `TestActor`'s queue, which is what the test wants for deterministic ordering.
- Pinning the `Engine` to `@MainActor` would have made production faster to write (no isolation parameter) but harder to test. The isolation-parameter approach pays a small ergonomic cost up front for a much larger payoff in test ergonomics.
- The `withEngine` fixture is the canonical test setup. It awaits `engine.cancelAll()` on exit, which breaks the listener-`Task` → `Engine` cycle before the next test; without that the test suite would leak `Task`s and grow until the OS pushed back.
- For Android, `Engine` is internal to `HackerNewsReader` and never crosses the JNI boundary — only `Core` does. The Android side never sees `Engine`'s isolation directly; it sees a `@MainActor Core` whose calls eventually `await` into the borrowed-executor actor. Both sides of that hop run on the same thread in production, so the hop is virtual.
