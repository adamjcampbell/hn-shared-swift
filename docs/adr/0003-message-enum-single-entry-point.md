# ADR-0003: `Message` enum funnels all mutations through one entry point

## Status

Accepted (2026-05-02). The original commits introduced this as `Codable AppEvent` routed through `dispatch(_:)`; the encoding requirement dissolved with [ADR-0013](0013-skipfuse-bridgemembers.md) (SkipFuse adoption, which carries enums across JNI as peer-backed Kotlin enums rather than as JSON) and the renames `AppEvent` → `Message` and `dispatch(_:)` → `sendMessage(_:)` followed shortly afterwards. The architectural shape — *one enum, one entry point* — is unchanged.

## Context

The shared `Model` has many fields that the UI may want to change: the search query, the read/unread set, the active loading task, error states. The two plausible ways to expose those changes to platform code are:

1. Per-mutation methods or setters: `model.setSearchQuery(_:)`, `model.toggleRead(_:)`, `model.refresh()`, one entry per change.
2. A single sum type listing every possible mutation, routed through one function: `sendMessage(.setSearchQuery(value:))`, `sendMessage(.toggleRead(id:))`, `sendMessage(.refresh)`.

Per-mutation methods spread mutation logic across many call sites and across the bridge surface — every new mutation is a new JNI entry point, a new bit of platform-side wiring. The single-funnel shape concentrates all mutation logic in one place: a `switch` on the message case inside the writer, top to bottom, no hidden coordinators, no callback graph.

This is the Elm shape — the application is a function from `(Model, Message) -> Model`. It is not Redux/TCA reducer composition (no nested reducers, no middleware) and it is not MVI (no per-screen presenters). It is the simplest version of the same idea: every UI input gets named, every mutation gets routed through one funnel.

## Decision

Mutations are expressed as cases of a single `enum Message` and dispatched through one entry point on the writer (`Engine.sendMessage(_ message: Message) async`). The platform wrapper exposes this through `SendMessageAction`, a `Sendable` callable struct that the UI invokes as `sendMessage(.toggleRead(id:))` (fire-and-forget) or `await sendMessage.run(.refresh)` (one-shot, await completion).

`Message` is `Sendable, Equatable`. It does not need `Codable`: it does not cross the JNI boundary as JSON; the Skip bridge carries it as a peer-backed Kotlin enum.

There are no setters on `Model`. There is no shortcut path. Every state change visible to the UI started as a `Message`.

## Consequences

- All mutation logic is grep-able in one location: the `switch` inside `Engine.sendMessage`.
- Adding a new mutation is one new `Message` case plus one new arm in the `switch`. No new bridge surface, no new JNI thunk, no platform-side glue.
- Tests drive the `Engine` by sending messages and asserting on `Model` reads. No mocking of intermediate types is required.
- The encoding (`Sendable` rather than `Codable`) is a consequence of the current bridge, not part of this decision. If the bridge regressed to a JSON wire format `Message` would gain `Codable` again without changing the funnel.
- Outbound side-effects (open a URL in Safari / Custom Tab, present an error toast) don't fit the inbound shape; those go through the separate `Command` stream — see [ADR-0006](0006-command-stream-side-effects.md).
