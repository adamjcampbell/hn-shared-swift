# ADR-0006: `Command` stream (core → UI) for one-shot side-effects

## Status

Accepted (2026-05-06). Originally introduced as `Codable AppCommand`; the encoding requirement dissolved with [ADR-0013](0013-skipfuse-bridgemembers.md) (SkipFuse bridges enums directly without JSON) and the rename `AppCommand` → `Command` followed. The architectural shape — *core emits one-shot side-effects on an `AsyncStream` consumed by the UI* — is unchanged.

## Context

[ADR-0003](0003-message-enum-single-entry-point.md) covers the inbound half of the UI ↔ core conversation: every UI mutation routes through a `Message` enum to one entry point. The outbound half is harder because not every outbound event fits naturally into the `@Observable` `Model`:

- Tapping a story should open its URL in `SFSafariViewController` on iOS or a Chrome Custom Tab on Android. This is a *one-shot imperative*, not a piece of state. Storing "the URL to open" as an observable field invites bugs: what if it's already open? What if the user backgrounds the app and returns? Observable state implies "this value is currently true"; one-shot effects don't have that semantics.
- A login failure or a fetch-failure that needs to be presented as a transient banner has the same shape: deliver it once, then it's gone.

Putting one-shot effects in `@Observable` state forces the consumer to invent "did I already handle this?" tracking. The alternative is a one-way stream from core to UI carrying values that the consumer is meant to react to but not retain.

## Decision

The `Core` exposes `commands: AsyncStream<Command>` — a hot stream of one-shot imperatives emitted by `Engine`. `Command` is a `Sendable, Equatable` enum (e.g. `.openURL(URL)`). The platform collects this stream once per app lifetime and reacts to each emission. The stream is finished only when the process ends.

Inbound and outbound are kept distinct:
- `Message` is UI → core, inbound, routed through one `sendMessage(_:)` entry point.
- `Command` is core → UI, outbound, delivered through one `AsyncStream<Command>`.

There is no facility for the UI to acknowledge a `Command` or "send it back". Acknowledgements happen implicitly: the UI did the thing the command asked for; if the user then sends a new `Message` the core observes the resulting state.

## Consequences

- The `@Observable` `Model` stays a pure-data container. Side-effects don't pollute it.
- Each platform writes ~10 lines to subscribe: a `for await command in core.commands` loop with a `switch` on the case. The iOS implementation feeds `IdentifiedURL` into a `.sheet`; Android calls `CustomTabsIntent.launchUrl`.
- The stream is *hot*. If the UI is not collecting when a `Command` is emitted, that command is lost. For the kinds of effects in scope (open a URL because the user just tapped a story) this is fine — the UI is always subscribed during foregrounded use. A future use case that needs replay across app launches would warrant its own ADR.
- The Elm-shaped vocabulary (`Message` in, `Command` out) is intentional. It maps cleanly onto the codebase and matches how the team talks about the design without inviting the rest of an Elm-architecture's machinery (composable updates, subscriptions, ports).
- Like `Message`, `Command`'s encoding is decoupled from this decision. It is `Sendable` because SkipFuse bridges enums directly; it was `Codable` in the era when the bridge crossed JNI as JSON. The stream contract survives the encoding choice.
