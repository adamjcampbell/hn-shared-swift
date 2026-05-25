# ADR-0019: Platform navigation owns comments routes; URL opening stays a command

## Status

Accepted (2026-05-25).

## Context

Story rows originally used their primary tap to open the submitted URL.
The shared `Engine` handled `Message.openStory(id:)` by marking the
story read and emitting `Command.presentURL`, which iOS rendered as a
Safari sheet and Android rendered as a Chrome Custom Tab.

The app now needs a comments screen. The primary row tap should drill
into comments, while URL opening should use a different explicit UX.
The navigation request is platform-specific:

- iOS should use state-based `NavigationStack` with a path.
- Android should use Navigation3's developer-owned back stack with
  `NavDisplay`.

Apple's Human Interface Guidelines treat list rows as a natural way to
navigate deeper into a hierarchy. Material 3 list guidance similarly
models a whole list item as one primary action, with supplementary
actions exposed explicitly instead of overloading the same tap target.

The shared package already owns state mutation, data loading, and
one-shot side effects. Platform UIs own view structure and presentation.
Putting a comments route into shared `Model` would mix platform
navigation concerns into the cross-platform data model.

## Decision

Comments navigation is platform-owned state.

On iOS, `RootView` owns a `[Route]` path and registers
`navigationDestination(for:)`. Row taps use a value-based navigation
link to push `.comments(storyID:)`.

On Android, the Compose root owns a Navigation3 back stack and renders
it with `NavDisplay`. Row taps add `CommentsRoute(storyId)` to that
back stack. The Navigation3 dependency is pinned to `1.0.1`, the stable
line compatible with the current Android Gradle Plugin after raising
`compileSdk` to 36.

The shared message contract separates intent:

- `viewStory(id:)` marks a story as read without presenting a URL.
- `openStoryURL(id:)` marks a story as read and emits
  `Command.presentURL` when the story has a URL.
- `loadComments(id:)` loads the story's comments idempotently.

`Command.presentURL` remains the one-shot URL presentation mechanism.
iOS still maps it to the Safari sheet, and Android still maps it to a
Custom Tab. The comments screen exposes URL opening as an explicit
toolbar / top-app-bar action.

Comments are fetched by the `HackerNews.Client` from the Firebase item
tree and flattened into shared `Comment` values. `Model` stores comments
by story id and projects `CommentRow` presenter values for both
platforms, following the `StoryRow` pattern from ADR-0017.

## Consequences

- The primary row action is now comments navigation on both platforms.
- Opening the submitted URL takes one explicit action from the comments
  screen. This avoids nested row controls and keeps accessibility clear.
- Back-stack restoration is platform-local. A restored comments route
  whose story is not loaded shows a missing-story state until a fetch-by-id
  path exists.
- URL side effects remain in `Command`, preserving the existing Safari /
  Custom Tab boundary.
- Comments loading is shared, tested once, and rendered from the same
  presenter rows on both platforms.
- Android now compiles against SDK 36 because Navigation3 1.0.1 and its
  navigation-event dependency require it. `targetSdk` is unchanged.
