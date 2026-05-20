# ADR-0001: One `@Observable` Model as cross-platform source of truth; state is ephemeral

## Status

Accepted (2026-05-02).

## Context

The project is a cross-platform Hacker News reader with native UIs on iOS (SwiftUI) and Android (Jetpack Compose). The shared logic — story list, search query, read/unread state, loading lifecycle, error handling — must run identically on both platforms while each UI reads it idiomatically.

Two model shapes are plausible:

1. A single `@Observable` Swift class instance that both platforms read directly.
2. A value-type model that exposes change events explicitly and is mirrored into platform-native observable wrappers.

Option 2 means writing more shared code (an explicit event-emission layer), losing free SwiftUI invalidation on iOS, and re-implementing the equivalent of `Observation` on Android.

Persistence is a related question. Adding a database (SwiftData on iOS, Room on Android) would introduce a second source of truth: state on disk plus state in memory. Migrations, schema versioning, and the cross-platform persistence layer all become problems before the core observation question is even answered.

## Decision

Use a single `@Observable final class Model` as the authoritative state container, owned by the Swift core and consumed directly by both UIs. iOS reads it through SwiftUI's built-in observation (SE-0395). Android reads its fields through the Skip bridge, which routes `@Observable` access into Compose's snapshot system (see [ADR-0013](0013-skipfuse-bridgemembers.md)).

State lives only in memory. On app restart the model is reconstructed fresh; the network is the only persistence layer. UI-local state that the user expects to survive (the search field's contents during process death) is restored by the view layer using `rememberSaveable` / `@SceneStorage`, not by `Model`.

## Consequences

- SwiftUI on iOS gets free invalidation: any `Model` field read inside a view body becomes a recomposition dependency without any glue.
- Adding a new piece of app state is one `@Observable` field on `Model` — no platform-specific mirror types.
- The fetch path is the only path: every cold start re-fetches the Hacker News front page. There is no offline mode and no replay of a previously-rendered list. For the size of payload this app deals with this is invisible to the user.
- Migrations are not a concern because there is no persisted schema. If a future feature genuinely needs persistence the introduction of a database would warrant its own ADR; doing so will break the "single source of truth" property and require an explicit synchronisation discipline between disk and `Model`.
- Mutation discipline is the price of letting both platforms share a non-`Sendable` reference type. The `Engine` actor (see [ADR-0016](0016-engine-actor-flat-model.md)) is what enforces it.
