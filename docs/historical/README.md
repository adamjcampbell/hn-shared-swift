# Historical design docs

These documents describe the project's previous architecture: a hand-written
JNI bridge built on `swift-java jextract` with per-property `appcoreObserve*`
thunks, a `JavaUIActor` global actor pinned to Android's main `Looper`, and
typed `*OnChange` SAM callbacks. That bridge shipped and worked, but in
2026-05 the project migrated to **SkipFuse** to get auto-bridged
`@Observable`→Compose state, `async`→`suspend`, `AsyncStream`→`Flow`, and
collections of structs as Kotlin lists — for free.

The migration narrative is in [`docs/skip-fuse-adoption.md`](../skip-fuse-adoption.md).

## What's in here

- **`swift-observable-compose-bridge-spec.md`** — the original 1300-line
  implementation spec. Useful as a "what we tried to build manually before
  taking the SkipFuse dependency" record.
- **`COMPARISON.md`** — 220-line analysis comparing observable-cross with
  Skip Fuse, written shortly before the migration. Captures the trade-offs
  that informed the decision.
- **`observation-bridge-mechanisms.md`** — five different ways to surface a
  Swift `@Observable` property as Compose state. Documents the willSet race
  that drove the original design.
- **`observation-bridge-tuple-return.md`** — fusion of `observe` + `read`
  into a single `(token, initialValue)` tuple-returning thunk, an
  optimisation specific to the deleted bridge.

These files reference symbols and files that no longer exist
(`AppCoreNative.swift`, `JavaUIActor`, `LooperExecutor`, `SwiftState.kt`,
etc.). Don't follow their instructions; read them as design archaeology.
