# ADR-0016: Single `Engine` actor as sole writer; `Model` is a flat mega-struct

## Status

Accepted (2026-05-17).

## Context

By 2026-05-17 the project had settled the bridge ([ADR-0013](0013-skipfuse-bridgemembers.md)), the executor story ([ADR-0014](0014-mainactor-both-platforms.md), [ADR-0015](0015-engine-borrows-host-executor.md)), and the inbound/outbound shape ([ADR-0003](0003-message-enum-single-entry-point.md), [ADR-0006](0006-command-stream-side-effects.md)). What remained was a question of internal structure: as the core grows, do the responsibilities get split into smaller types — a `LoadableStories` here, an `AppEventHandler` there — or stay concentrated?

Two pressures were in tension:

- **Vertical-slicing instinct.** "A `LoadableStories` type that owns the front-page list, its loading state, and its error" feels naturally cohesive. Each axis of behaviour gets its own type. The reducer-style architecture this is descended from rewards this kind of decomposition.
- **Locality of Behaviour.** When `dispatch(.refresh)` needs to coordinate updates across multiple axes — clear the search results, set the front-page to loading, kick off the fetch — splitting state into wrapper types means the dispatch arm has to reach across those wrappers, often via methods that exist only to forward writes. The wrappers' value is largely paid back to the dispatch arms that thread through them.

The "split each axis into its own type" instinct, applied without restraint, produces a tree of wrappers whose only job is to bundle two or three fields. Cohesion within each wrapper is local; coordination across wrappers leaks back into the top-level dispatch. The mutation logic becomes harder to read, not easier — `state.feed.loadStatus.value = .loading` instead of `state.feedLoadStatus = .loading`.

The semantic-compression bar from Casey Muratori's work on code structure is the relevant heuristic here: a wrapper type earns its keep when it satisfies at least two of (a) operation repetition — the wrapper is used in many places the same way, (b) temporal access coupling — the wrapper's fields are accessed together within the same operation, (c) Carmack-lightweight — the wrapper does something genuinely cheap and self-evident. A wrapper that bundles two fields used together once or twice fails all three.

## Decision

`Model` is a flat `@Observable final class` with one field per axis of state. New state lands as a new field on `Model`, not as a member of a wrapper. The fields cover: stories (feed list, search results), loading status per axis, search query, the read-stories id set, last-refreshed timestamp, error states, pagination cursors.

`Engine` is a `final actor` (see [ADR-0015](0015-engine-borrows-host-executor.md)) that owns every mutation. The class methods on `Model` are not mutators in the usual sense — there are no setters that encode business logic. `Model` is essentially a public data bag; the rules live on `Engine`. The discipline is explicit: `Engine` is the only writer of `Model`. Do not add mutators on `Model`.

A nested type earns its keep on `Model` when ≥ 2 of the semantic-compression criteria apply. `LoadStatus` (idle/loading/error coexisting during retry) and `LoadedStories` (paginated list + cursor + hasNext) qualify because they are used identically across multiple axes. Wrappers that don't meet the bar — `LoadableStories` was an early candidate — get dissolved into flat `Model` fields.

## Consequences

- Mutation logic is concentrated. The `switch` inside `Engine.sendMessage` is one screen for the whole app, top to bottom. A reader can find the entire effect of `.refresh` or `.toggleRead` without traversing a type tree.
- New state is one line on `Model` plus one arm on the dispatch switch. No new wrapper, no new file.
- Field names get prefixed where context isn't obvious — `feedLoadStatus`, `searchLoadStatus`, `feedHasNext`, `searchHasNext`. The prefix replaces the namespace a wrapper would have provided. The cost is verbose field names; the benefit is no indirection at the access site.
- Refactors that would extract a wrapper type are deferred until the bar is met. Until then the additional axis lives as a flat field on `Model`.
- For tests the flat shape is a feature. `engine.run { engine in let model = engine.model; #expect(model.feedStatus == .loaded(...)) }` reads naturally. A wrapper would force `model.feed.status` or `model.feed.loadStatus`, adding rather than removing noise.
- The single-`Engine` shape is not scalable in the "10 different developers want to add their feature" sense. For a one-author / small-team project this is the right cost; for a large team the locality benefit would need to be re-weighed against the coordination cost of one big `dispatch` arm. Either way, the choice is explicit rather than emerging by accident.
