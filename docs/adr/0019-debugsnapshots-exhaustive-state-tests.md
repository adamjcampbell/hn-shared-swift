# ADR-0019: `@DebugSnapshot` on `Model` for exhaustive engine/state tests

## Status

Accepted (2026-05-27).

## Context

`Engine` is the sole writer of `Model`; engine tests drive a `Message`
and assert the resulting state. The existing tests read individual
fields through `#expect`, which asserts only what each test names — a
message that mutates an unexpected field passes silently.

Exhaustive assertion of the state delta (the `TestStore` model: snapshot
before and after, then assert on exactly what changed) is the goal.
`Model` is a reference-type `@Observable` bag and is deliberately not
`Equatable`, so a plain `==` snapshot is unavailable.

Point-Free's [swift-debug-snapshots](https://github.com/pointfreeco/swift-debug-snapshots)
fills the gap: the `@DebugSnapshot` macro generates an inert value
snapshot of a class's stored state, and `expect(_:operation:changes:)`
snapshots the instance before and after a block and forces an exhaustive
assertion on the delta — an undeclared change fails the test. It targets
`@Observable` reference types and needs no `Equatable` conformance.

The boundary concern was that `Model` compiles for Android via Skip
Fuse, and an attached macro expands on every target — including the
Android compile. Two facts resolved it:

- skipstone bridges the *written* source, not macro-synthesised
  declarations. The generated `DebugSnapshot` / `DebugSnapshotValue` /
  `_debugSnapshot` members never reach the Kotlin surface, even though
  `Model` carries `// SKIP @bridgeMembers`.
- Skip Fuse compiles against the official Swift SDK for Android, which
  ships the full standard library and Foundation. The only runtime
  dependency the macro adds is swift-custom-dump, which needs `Mirror`
  plus Foundation; it cross-compiles into the Android AAR. A full
  `skip export` confirms the expansion and CustomDump build for the
  Android target.

Alternatives considered:

- **Apple-gate the macro** — `#if canImport(DebugSnapshots)` around the
  import and attributes (SE-0367) plus a `.when(platforms:)` Apple-only
  dependency. Deterministically keeps it off Android, but adds
  conditional-compilation ceremony and would also have to gate
  `@DebugSnapshotIgnored`. Held as the fallback if a future version
  stops cross-compiling for Android.
- **Manual `DebugSnapshotConvertible` conformance in the test target** —
  no macro on `Model`, the conformance hand-written to mirror the macro
  expansion. Leaves `Model` untouched at the cost of underscored-API
  boilerplate, and loses the logging mode.

## Decision

`@DebugSnapshot` is applied to `Model` unconditionally, alongside
`@Observable`. swift-debug-snapshots is a dependency of the
`HackerNewsReader` target (for the macro) and the `HackerNewsReaderTests`
target (for `expect`).

The snapshot is shaped to the observable UI surface, not the raw store.
It covers `searchQuery`, the six feed/search load axes, and the two
projections the views actually render — `feedStories` and
`searchResults` — which are computed, so they carry `@DebugSnapshotTracked`
to opt them in (computed properties are ignored by default). The
normalised entity store is named `_stories` / `_readIds`: the macro
ignores underscore-prefixed properties by rule, which keeps the
redundant source-of-truth out of the snapshot and signals "internal
storage, reach in only via `@testable`". `searchQueryChanges` (an
`AsyncStream`) keeps `@DebugSnapshotIgnored`; `searchQueryEvents`
(`private`) is excluded automatically. `feedHeaderSubtitle` is left
untracked — its localised time-stamp string is brittle to assert.

Tests call `expect(engine.model) { await engine.sendMessage(.x) }
changes: { … }` inside `engine.run { … }`, so the non-`Sendable`
`Model` is read on the `Engine` / `TestActor` isolation; the async
`expect` overload awaits the message.

## Consequences

- An engine message that mutates a field not declared in `changes:`
  fails the test, surfacing unintended writes as the reducer grows.
  `Model` stays non-`Equatable`.
- `expect` asserts `Model` snapshot state only. `Command` emissions and
  debounce timing keep their existing patterns — the `commands`
  iterator and `TestClock`.
- The macro's `.logChanges` mode instruments a type's own methods, so it
  can't reach `Model` (the `Engine` is the writer). Logging is wired
  instead through an injected `Dependencies.changeLogger` (`ChangeLogger`,
  a `@Sendable` capture-and-finish closure). The `Engine` calls it around
  each mutation — `sendMessage(_:)` and the search listener's commit and
  clear — labelling each with the `Message` or the query. Production
  injects `.none` (no snapshot, no log; `Engine` doesn't even import
  DebugSnapshots), and `withEngine` injects a logger that `snap`s and
  `_logChanges` the diff, so the snapshot/diff machinery lives in the test
  target. Output is `os.Logger` (subsystem `DebugSnapshots`) on Apple,
  `print` elsewhere, so it stays out of `swift test` stdout unless
  surfaced. The `@TaskLocal` propagates into the listener `Task` because
  `withEngine` binds it around `bind()`.
- The Android AAR carries swift-custom-dump as unreachable code; the
  snapshot path is never called from the Engine or the UI.
- swift-debug-snapshots is a 0.x beta and the generated conformance
  references underscored runtime types. A breaking bump requires a
  re-verify against the Android compile; the Apple-gate alternative is
  the escape hatch if cross-compilation ever regresses.
- The snapshot is deterministic only under a pinned `Dependencies.date`:
  `loadedAt` and the projected `StoryRow.metaLine` both read it, so an
  unpinned `now` makes an otherwise-unchanged `feedStories` diff between
  the before/after snapshots. The `withEngine(now:)` fixture pins it.
