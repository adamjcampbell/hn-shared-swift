# ADR-0017: Presenter rows projected from `Model`; the package owns the view shape

## Status

Accepted (2026-05-21).

## Context

By 2026-05-21 the package had settled the shape of state, mutation,
and bridging ([ADR-0001](0001-observable-model-source-of-truth.md),
[ADR-0013](0013-skipfuse-bridgemembers.md),
[ADR-0016](0016-engine-actor-flat-model.md)). What it had not settled
was where the view's *presentation* of a story actually lives. A story
row on either platform needs the title, a meta caption ("by alice ·
12 points · 4 comments · example.com · 3h ago"), a host extracted from
the URL, and a swipe-action label that flips on read state. SwiftUI
could compute those inside the row view; Compose could compute them
inside its `@Composable`. Two constraints rule that out:

- **`RelativeDateTimeFormatter` does not bridge through
  skip-foundation.** Any cross-platform relative-age string has to be
  written in plain Swift if both surfaces are to read the same value
  for the same input.
- **`Model` already holds the entity store and the read-id set.** The
  data needed to materialise a row lives on one side of the bridge.
  Recomputing the same caption on both platforms would split a single
  semantic into two implementations that drift.

Tests have a related constraint. A row's `metaLine` reads "3h ago"
against a reference `now`. If `now` is wall-clock `Date()`, assertions
either pin time externally (a global concern) or test only the
time-independent fields.

## Decision

Project `Story` + `isRead` + a reference time into a `StoryRow` value
type at the package layer. `StoryRow` is a `Sendable`, `Identifiable`,
`Equatable` `struct` with `// SKIP @bridgeMembers` for whole-type
bridging. Its initialiser precomputes the presentation strings —
`displayHost`, `metaLine`, `readActionLabel` — so the views consume
properties, not lambdas.

Rows are vended through `Model.feedStories` and `Model.searchResults`:
computed properties that walk the surface's ordered id list, look
each id up in the normalised `[id: Story]` store, and construct a
`StoryRow` per id. Both projections capture a single reference time
from `Dependencies.date.now` so every row in one projection shares
the same `now` snapshot.

`Dependencies` is a single `@TaskLocal DateGenerator`. The
`DateGenerator` shape is borrowed from `pointfreeco/swift-dependencies`
(`@Dependency(\.date.now)`) without adopting the library itself — the
macros and runtime infrastructure don't fit Skip's Android Swift
target. Production reads default to wall-clock `Date()`; the test
fixture `withEngine` opens a `Dependencies.$date.withValue(...)`
binding around `bind()` and the test body so listener tasks and
projections all observe the same pinned `now`.

The catalog-based `Strings` enum ([ADR-0018](0018-localized-strings-catalog-generator.md))
is the other half of this layer: `readActionLabel` is
`Strings.markRead` / `Strings.markUnread`, so the row's presentation
flows through the same localization path as the rest of the UI chrome.

## Consequences

- Both platforms render properties (`row.metaLine`,
  `row.readActionLabel`, `row.displayHost`); neither runs a
  `Date.now` read or a string-formatting routine inside its view
  body. SwiftUI `StoryRowView` and Compose `StoryRowView` consume
  the same precomputed strings for the same input.
- The relative-age bucket lives once, in `StoryRow`, as pure
  Swift. `Foundation.RelativeDateTimeFormatter`'s skip-foundation
  gap is sidestepped without per-platform duplication.
- `Model.feedStories` recomputes on every read. `@Observable`
  tracking refires on changes to the entity store, `feedLoaded`,
  `readIds`, or `searchQuery` — anything the projection reads. Cost
  is bounded by the front-page count (≤ 30 rows by default) and is
  cheap relative to a Compose recompose or a SwiftUI list diff.
- `Dependencies` adds one `@TaskLocal` at the package boundary.
  Tests pin time with `Dependencies.$date.withValue(.constant(_:)) { … }`;
  the fixture `withEngine` wraps its body in that binding so listener
  tasks observe the same `now` as the test body. No clock parameter
  threads through Engine signatures purely for presenter time.
- Equatable `StoryRow` lets SwiftUI's per-row diffing and Compose's
  stability checks skip unchanged rows. Adding a new presentation
  field is one stored property + one assignment in the initialiser;
  consumers don't change.
- Projections sit alongside state and mutation as a third layer in
  the package. Additional row types use the same shape: a value type
  with `// SKIP @bridgeMembers`, a projection method on `Model`, and
  a `Dependencies.date` capture where time enters.
