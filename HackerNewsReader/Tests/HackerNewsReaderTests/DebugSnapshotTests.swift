import DebugSnapshots
import Foundation
import Testing
@testable import HackerNewsReader
import HackerNews

/// `expect` snapshots `Model` before and after an `Engine` message and
/// forces an exhaustive assertion on the delta — any tracked state that
/// changes but isn't declared in `changes:` fails the test. `Model` is
/// a non-`Equatable` `@Observable` class; the `@DebugSnapshot` macro on
/// it supplies the inert value snapshot `expect` diffs.
///
/// The snapshot is the observable UI surface: `searchQuery`, the load
/// axes, and the `@DebugSnapshotTracked` projections `feedStories` /
/// `searchResults`. The internal `_stories` / `_readIds` store is
/// underscore-ignored, so assertions read in terms of the rows the UI
/// renders.
///
/// `expect` reads the non-`Sendable` `Model` synchronously, so it runs
/// inside `engine.run { … }` (the `Engine` / `TestActor` isolation); the
/// async overload lets `operation` `await` the message. `withEngine`
/// pins `Dependencies.date` to `fixedNow`, so `StoryRow.metaLine` (and
/// thus the captured rows) are deterministic.
@Suite("DebugSnapshot")
struct DebugSnapshotTests {
    @Test("refresh populates the feed")
    func refresh() async throws {
        try await withEngine(
            client: .mock(frontPage: { _ in page([storyA, storyB]) }),
            now: { fixedNow }
        ) { engine in
            await engine.run { engine in
                await expect(engine.model) {
                    await engine.sendMessage(.refresh)
                } changes: {
                    $0.feedLoaded = LoadedStories(
                        ids: [storyA.id, storyB.id],
                        page: 0,
                        totalPages: 1,
                        loadedAt: fixedNow
                    )
                    $0.feedStories = [
                        StoryRow(story: storyA, isRead: false, now: fixedNow),
                        StoryRow(story: storyB, isRead: false, now: fixedNow),
                    ]
                    // feedInitialStatus: startLoading -> finishSuccess
                    // returns to the default, so there's no net change.
                }
            }
        }
    }

    @Test("openStory marks the story read; presentURL is a command, not state")
    func openStory() async throws {
        try await withEngine(
            client: .mock(frontPage: { _ in page([storyA, storyB]) }),
            now: { fixedNow }
        ) { engine in
            await engine.sendMessage(.refresh)

            var commands = engine.commands.makeAsyncIterator()
            await engine.run { engine in
                await expect(engine.model) {
                    await engine.sendMessage(.openStory(id: storyA.id))
                } changes: {
                    $0.feedStories = [
                        StoryRow(story: storyA, isRead: true, now: fixedNow),
                        StoryRow(story: storyB, isRead: false, now: fixedNow),
                    ]
                }
            }
            #expect(await commands.next() == .presentURL(value: storyA.url!))
        }
    }
}
