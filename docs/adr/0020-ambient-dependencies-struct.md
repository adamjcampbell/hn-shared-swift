# ADR-0020: Ambient `Dependencies` struct; read `date` / `client` / `clock` at the call site

## Status

Accepted (2026-06-01).

## Context

The free-function core ([ADR-0019](0019-core-free-functions-uicore-split.md)) threaded `client` and `clock` through every signature — `makeCore`, `apply`, `applySearchQuery`, `fetch`, `loadTask` — purely to hand them to the leaf that fetches or sleeps. `date` was already ambient (a `@TaskLocal` in `Dependencies`). Two of the three injectables polluted call layers that never touch them directly: only `fetch` reads the clock, and only the fetch closures use the client.

`pointfreeco/swift-dependencies` solves this with an ambient `DependencyValues` read at the use site. The library itself was rejected when the bridge moved to SkipFuse ([ADR-0013](0013-skipfuse-bridgemembers.md)) because its macros and runtime don't fit Skip's Android Swift target. The *pattern* — values read ambiently rather than threaded — is still what's wanted.

Two shapes were weighed for a hand-rolled version:

- The library's real design: a struct wrapping `[ObjectIdentifier: any Sendable]`, one `DependencyKey` per dependency with a `liveValue`, accessed by key type or key path.
- A plain struct with one typed field per dependency, held in a single `@TaskLocal`.

## Decision

`Dependencies` is a `Sendable` struct with three stored fields — `date`, `client`, `clock` — held in one `@TaskLocal static var current`, with live defaults (`Date()`, `Client()`, `ContinuousClock()`) that match the old parameter defaults exactly. Call sites read `Dependencies.current.client` / `.clock` / `.date.now`. `makeCore`, `apply`, `applySearchQuery`, `fetch`, and `loadTask` drop their `client:` / `clock:` parameters.

The dictionary form was rejected. Its one advantage — open extensibility, a distant module adding a key without touching a central type — serves nothing here: three fixed injectables in one module. Against that it costs a `DependencyKey` per dependency, `Any`-boxing the existential clock, and a runtime downcast on every read. The struct is the compressed form: typed, no erasure, no per-key boilerplate, trivially Skip-compatible (a plain `Sendable` struct using the same `@TaskLocal` and `any Clock<Duration>` constructs the package already shipped). All three values are already `Sendable` — `DateGenerator`; `Client` is a `Sendable` struct of `@Sendable` closures; `Clock` refines `Sendable` — so the struct lives in a `@TaskLocal` safely.

Production reads the live defaults ambiently with no `withValue` on the stack. Tests bind a `Dependencies` value once via `Dependencies.$current.withValue(...)`; the `withCore` fixture does this and calls `makeCore` *inside* the binding, so the listener `Task` and every fetch the test triggers inherit the pinned deps (task-local values propagate into unstructured `Task`s at the point they are spawned). A subset is overridden by copy-and-mutate (`var d = Dependencies.current; d.date = .constant(t)`), which is how `PresentationTests` pins time without disturbing `client` / `clock`. The test still holds its own `TestClock` reference to call `advance(_:)`; the clock is ambient for the core, not for the test driving it.

## Consequences

- The core's load/fetch signatures shrink to `state` / `commands` / `tasks` / `isolation`. `client` and `clock` are read where used (`fetch`) instead of carried through three call layers.
- The injection seam is one `@TaskLocal`, not a parameter chain. Adding a dependency is one field plus its default; there is no key type to declare.
- `isolation` threading ([ADR-0019](0019-core-free-functions-uicore-split.md)) is untouched and orthogonal: it selects the executor a spawned `Task` runs on; the task-local selects the values that `Task` sees.
- The fixture's correctness now depends on `makeCore` running inside the `withValue` — the listener captures the ambient deps at spawn. Calling it outside would silently fall back to the live `Client` / `ContinuousClock` and ignore the mock and `TestClock`. This is the one sharp edge the struct introduces over parameter threading; the search/timing tests are the canary (they hang on the live clock if it regresses).
- `Dependencies` stays `internal` and unbridged; the JNI surface (`UICore`, `Model`, `SendMessageAction`, the HN domain types) is unchanged.
- Adopting the swift-dependencies *library* remains rejected for the Skip reason in [ADR-0013](0013-skipfuse-bridgemembers.md); this records that the ambient-value pattern is reproduced by hand at the scale this app needs.
