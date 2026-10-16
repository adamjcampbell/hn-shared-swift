import Foundation
import Testing
import HackerNews
@testable import HackerNewsReader

@Suite(.timeLimit(.minutes(1)))
struct AndroidReaderTests {
    @Test @MainActor
    func cancelledWaiterClearsOnlyItsOwnLoadingStatus() async {
        let (started, start) = AsyncStream<Void>.makeStream()
        var dependencies = Dependencies.current
        dependencies.client = .mock(frontPage: { _ in
            start.yield(())
            try await ContinuousClock().sleep(for: .seconds(3600))
            return Page(stories: [], totalPages: 1)
        })
        await Dependencies.$current.withValue(dependencies) {
            let core = makeCore()
            defer { core.cancelAll() }
            let action = SendMessageAction(core)
            var starts = started.makeAsyncIterator()
            let first = Task { await action.run(.refresh) }
            _ = await starts.next()
            let second = Task { await action.run(.refresh) }
            _ = await starts.next()
            first.cancel()
            await first.value
            #expect(core.model.feedInitialStatus.isLoading)
            second.cancel()
            await second.value
            #expect(!core.model.feedInitialStatus.isLoading)
            #expect(core.model.feedInitialStatus.error == nil)
            #expect(core.model.feedLoaded == nil)
        }
    }

    @Test @MainActor
    func closeCancelsInflightWorkAndCompletesWaitingCaller() async {
        let (started, start) = AsyncStream<Void>.makeStream()
        let (cancelled, cancel) = AsyncStream<Void>.makeStream()
        var dependencies = Dependencies.current
        dependencies.client = .mock(frontPage: { _ in
            start.yield(())
            do { try await ContinuousClock().sleep(for: .seconds(3600)) }
            catch { cancel.yield(()); throw error }
            return Page(stories: [], totalPages: 1)
        })
        await Dependencies.$current.withValue(dependencies) {
            let bridge = AndroidReader(core: makeCore())
            let (completed, completion) = AsyncStream<Bool>.makeStream()
            _ = bridge.start(.refresh) { completion.yield($0) }
            var starts = started.makeAsyncIterator()
            _ = await starts.next()
            bridge.close()
            var completions = completed.makeAsyncIterator()
            #expect(await completions.next() == false)
            var cancellations = cancelled.makeAsyncIterator()
            _ = await cancellations.next()
        }
    }

    @Test @MainActor
    func cancellationDoesNotCancelAnotherAction() async {
        let core = makeCore()
        let bridge = AndroidReader(core: core)
        defer { bridge.close() }
        let (events, continuation) = AsyncStream<Bool>.makeStream()
        let cancelled = bridge.start(.toggleRead(id: "cancelled")) { continuation.yield($0) }
        bridge.cancel(cancelled)
        _ = bridge.start(.toggleRead(id: "kept")) { continuation.yield($0) }
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == false)
        #expect(await iterator.next() == true)
        #expect(core.model.readIds == ["kept"])
    }

    @Test @MainActor
    func cancellingAnInflightActionCancelsItsRequest() async {
        let (started, start) = AsyncStream<Void>.makeStream()
        let (cancelled, cancel) = AsyncStream<Void>.makeStream()
        var dependencies = Dependencies.current
        dependencies.client = .mock(frontPage: { _ in
            start.yield(())
            do { try await ContinuousClock().sleep(for: .seconds(3600)) }
            catch { cancel.yield(()); throw error }
            return Page(stories: [], totalPages: 1)
        })
        await Dependencies.$current.withValue(dependencies) {
            let bridge = AndroidReader(core: makeCore())
            defer { bridge.close() }
            let token = bridge.start(.refresh) { _ in }
            var starts = started.makeAsyncIterator()
            _ = await starts.next()
            bridge.cancel(token)
            var cancellations = cancelled.makeAsyncIterator()
            _ = await cancellations.next()
            #expect(bridge.feedLoaded == nil)
        }
    }

    @Test @MainActor
    func projectionsObserveSharedStoreAndPreserveValues() async {
        let core = makeCore()
        let bridge = AndroidReader(core: core)
        defer { bridge.close() }
        let date = Date(timeIntervalSince1970: 1_700_000_123.5)
        core.model.stories = ["a": Story(id: "a", title: "Swift é 😀 %@", author: "author",
            score: 17, commentCount: 3, url: "https://example.com/a", createdAt: date)]
        core.model.feedLoaded = LoadedStories(ids: ["a"], page: 2, totalPages: 5, loadedAt: date)
        core.model.searchLoaded = LoadedStories(ids: ["a"], page: 0, totalPages: 1, loadedAt: date)
        #expect(bridge.feedStories.first?.title == "Swift é 😀 %@")
        #expect(bridge.feedStories.first?.createdAt == 1_700_000_123.5)
        #expect(bridge.feedLoaded?.page == 2)
        #expect(bridge.feedLoaded?.nextPage == 3)
        let (events, continuation) = AsyncStream<Void>.makeStream()
        _ = bridge.observeSearchResults { continuation.yield(()) }
        _ = bridge.start(.toggleRead(id: "a")) { _ in }
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        #expect(bridge.feedStories.first?.isRead == true)
        #expect(bridge.searchResults.first?.isRead == true)
        core.model.stories.removeValue(forKey: "a")
        _ = await iterator.next()
        #expect(bridge.searchResults.isEmpty)
    }

    @Test @MainActor
    func commandConsumerCanDetachAndReattach() async {
        let core = makeCore()
        let bridge = AndroidReader(core: core)
        defer { bridge.close() }
        core.model.stories = ["a": Story(id: "a", title: "Title", author: "author", score: 1,
            commentCount: 0, url: "https://example.com/a", createdAt: .now)]
        let (events, continuation) = AsyncStream<Void>.makeStream()
        var iterator = events.makeAsyncIterator()
        for _ in 0..<2 {
            let token = bridge.observeCommands { continuation.yield(()) }
            _ = bridge.start(.openStory(id: "a")) { _ in }
            _ = await iterator.next()
            #expect(bridge.takeCommand() == .presentURL(value: "https://example.com/a"))
            #expect(bridge.takeCommand() == nil)
            bridge.cancel(token)
        }
    }
}
