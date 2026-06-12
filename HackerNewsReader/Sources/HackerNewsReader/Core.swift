import Foundation
import Observation
import HackerNews
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Core (isolation-generic, bridged)

/// Identities for the in-flight Tasks ``makeCore`` coordinates through
/// a single ``TaskRegistry``.
enum TaskID { case feed, feedMore, search, searchMore, searchListener }

/// The single handle behind the UI: the observable ``Model``, the
/// one-shot command stream, an async send-message entry, and a teardown
/// hook. One `Core` serves every consumer — `MainActor` production (built
/// via ``makeAppCore``) and `TestActor` tests (built via ``makeCore``).
///
/// ``makeCore`` binds its `isolation` parameter into the ``TaskRegistry``'s
/// spawn closure, so the host actor owns every mutation. ``Model`` is
/// non-`Sendable` and never leaves that region. Production wraps
/// ``sendMessage`` in a `@MainActor` ``SendMessageAction`` at the app
/// boundary (`SendMessageAction(core)`); only ``model`` and ``commands``
/// cross JNI.
// SKIP @bridgeMembers
public struct Core {
    public let model: Model

    public let commands: AsyncStream<Command>

    /// Applies a `Message` to the model. Non-`Sendable` — it captures the
    /// `Model` and the task registry — so the type system confines every
    /// caller to the region `makeCore` was formed on, and the body runs
    /// there: `MainActor` in production, a `TestActor` in tests. The
    /// listener `Task` and the fetch work share that same isolation, so
    /// every `Model` / registry write stays serialised.
    ///
    /// `internal` so app code reaches it only through the `@MainActor`
    /// ``SendMessageAction`` that wraps it; tests in-module call it
    /// directly on their `TestActor`. Concurrent UI entry points (a
    /// fire-and-forget tap plus a `.refreshable`) serialise at that
    /// `@MainActor` boundary; the synchronous
    /// ``apply(_:to:commands:tasks:)`` keeps each handler's
    /// read-modify-write atomic against actor reentrancy.
    // SKIP @nobridge
    let sendMessage: (Message) async -> Void

    /// Cancels the listener and any in-flight fetch. Production is
    /// process-lifetime and never calls this; tests call it on fixture
    /// exit so the `Task → Model` references release.
    // SKIP @nobridge
    let cancelAll: () -> Void

    /// Debounce window between a `model.searchQuery` write and the
    /// resulting search fetch.
    // SKIP @nobridge
    static let searchDebounce: Duration = .milliseconds(250)
}

/// Composes the core: builds the command stream and the task registry,
/// spawns the search listener, and returns the ``Core`` handle.
///
/// `isolation` appears here and nowhere else. It is bound once, into the
/// registry's spawn closure: the spawned `Task` references the isolated
/// parameter (`_ = isolation`) so it captures it and runs on the host
/// actor — without that reference a `Task` infers `@concurrent` and
/// fails to compile against the non-`Sendable` captures. Every other
/// function in this file is synchronous (runs where it is called) or
/// `nonisolated(nonsending)` async (runs on its caller's actor), and all
/// callers trace back to this region, so no further threading is needed.
///
/// The listener, the send closure, and `cancelAll` all capture the one
/// ``TaskRegistry``; the registry, the `Model`, and both closures are
/// non-`Sendable`, so everything stays confined to `isolation`'s region
/// and the writes stay serialised.
///
/// - Parameters:
///   - model: The observable state; defaults to a fresh ``Model``.
/// - Returns: The ``Core`` handle.
func makeCore(
    model: sending Model = Model(),
    isolation: isolated any Actor = #isolation
) -> Core {
    let state = model
    let (commands, commandsContinuation) = AsyncStream<Command>.makeStream()
    let tasks = TaskRegistry<TaskID> { work in
        Task {
            _ = isolation
            await work()
        }
    }

    tasks.run(.searchListener) {
        for await query in state.searchQueryChanges {
            applySearchQuery(query, to: state, tasks: tasks)
        }
    }

    return Core(
        model: state,
        commands: commands,
        sendMessage: { message in
            await apply(
                message,
                to: state,
                commands: commandsContinuation,
                tasks: tasks
            )?.value
        },
        cancelAll: { tasks.cancelAll() }
    )
}

// MARK: - Message handling

/// Applies a user-driven ``Message`` to `state`: mutates the model in
/// place, yields any ``Command``, and registers in-flight fetch work.
///
/// Synchronous, so it runs on whatever actor calls it — always the host
/// actor, because every caller closes over the non-`Sendable` `state`
/// and registry — and cannot span a suspension: the host actor
/// serialises *execution steps*, not whole handlers, so an `await`
/// inside a handler's read-modify-write window would let actor
/// reentrancy interleave a second handler and lose updates. The
/// `.refresh` / `.loadMore` arms return their spawned `Task` so the
/// caller can `await` its value after the mutation is committed.
///
/// - Parameters:
///   - message: The message to apply.
///   - state: The model to mutate.
///   - commands: Continuation for one-shot UI commands.
///   - tasks: Registry that spawns the fetch work and owns its
///     cancellation.
/// - Returns: The spawned fetch `Task` for `.refresh` / `.loadMore`
///   (so `.refreshable` can hold its spinner), `nil` otherwise.
@discardableResult
func apply(
    _ message: Message,
    to state: Model,
    commands: AsyncStream<Command>.Continuation,
    tasks: TaskRegistry<TaskID>
) -> Task<Void, Never>? {
    switch message {

    case .toggleRead(let id):
        if state.readIds.contains(id) {
            state.readIds.remove(id)
        } else {
            state.readIds.insert(id)
        }
        return nil

    case .openStory(let id):
        guard let story = state.stories[id] else { return nil }
        state.readIds.insert(id)
        if let url = story.url {
            commands.yield(.presentURL(value: url))
        }
        return nil

    case .refresh:
        // Cancel in-flight load-more so its page doesn't append onto the snapshot we're replacing.
        tasks.cancel(.feedMore)
        state.feedLoadMoreStatus = LoadStatus()
        state.feedInitialStatus.startLoading()

        return load(.feed, into: state, status: \.feedInitialStatus, tasks: tasks) {
            try await $0.frontPage(0)
        } commit: { page, ids in
            state.feedLoaded = LoadedStories(
                ids: ids, page: 0, totalPages: page.totalPages, loadedAt: Dependencies.current.date.now
            )
        }

    case .loadMore where state.searchQuery.isEmpty:
        guard let loaded = state.feedLoaded, loaded.hasMore,
              !state.feedLoadMoreStatus.isLoading else { return nil }
        let next = loaded.nextPage
        state.feedLoadMoreStatus.startLoading()

        return load(.feedMore, into: state, status: \.feedLoadMoreStatus, tasks: tasks) {
            try await $0.frontPage(next)
        } commit: { page, ids in
            state.feedLoaded?.appendPage(ids, totalPages: page.totalPages)
        }

    case .loadMore:
        guard let loaded = state.searchLoaded, loaded.hasMore,
              !state.searchLoadMoreStatus.isLoading else { return nil }
        let query = state.searchQuery
        let next = loaded.nextPage
        state.searchLoadMoreStatus.startLoading()

        return load(.searchMore, into: state, status: \.searchLoadMoreStatus, tasks: tasks) {
            try await $0.search(query, next)
        } commit: { page, ids in
            state.searchLoaded?.appendPage(ids, totalPages: page.totalPages)
        }
    }
}

/// Applies a debounced `model.searchQuery` change: clears search state
/// on an empty query, otherwise marks loading and spawns the search
/// fetch into the registry's `.search` slot.
///
/// Synchronous for the same reason as ``apply(_:to:commands:tasks:)``:
/// the listener invokes it inside its `for await` loop, so the
/// read-modify-write must not span a suspension.
///
/// - Parameters:
///   - query: The current search query.
///   - state: The model to mutate.
///   - tasks: Registry that spawns the search fetch and owns its
///     cancellation.
func applySearchQuery(
    _ query: String,
    to state: Model,
    tasks: TaskRegistry<TaskID>
) {
    if query.isEmpty {
        tasks.cancel(.search)
        tasks.cancel(.searchMore)
        state.searchLoaded = nil
        state.searchInitialStatus = LoadStatus()
        state.searchLoadMoreStatus = LoadStatus()
        return
    }

    tasks.cancel(.searchMore)
    // @Observable re-fires on equal writes; skip no-ops during keystroke bursts.
    if state.searchLoadMoreStatus != LoadStatus() {
        state.searchLoadMoreStatus = LoadStatus()
    }
    if !state.searchInitialStatus.isLoading {
        state.searchInitialStatus.startLoading()
    }

    load(
        .search, into: state, status: \.searchInitialStatus, tasks: tasks,
        debounce: Core.searchDebounce
    ) {
        try await $0.search(query, 0)
    } commit: { page, ids in
        state.searchLoaded = LoadedStories(
            ids: ids, page: 0, totalPages: page.totalPages, loadedAt: Dependencies.current.date.now
        )
    }
}

/// Sleeps for `debounce` (if set), then runs `body`.
///
/// `nonisolated(nonsending)`, so the debounce sleep and its post-sleep
/// continuation resume on the calling task's actor — tests drive a
/// `TestClock` and drain the actor's queue deterministically, which only
/// works because the sleeper resumes there.
///
/// - Parameters:
///   - debounce: Delay before invoking `body`, or `nil` for none.
///   - body: Closure that issues the page fetch.
/// - Returns: The page produced by `body`.
/// - Throws: Whatever `body` throws, plus `CancellationError` if the
///   surrounding task is cancelled.
/// - Note: `URLSession` surfaces task cancellation as
///   `URLError.cancelled`; this rethrows it as `CancellationError` so
///   callers can match cancellation the same way regardless of transport.
func fetch(
    debounce: Duration?,
    body: @Sendable (Client) async throws -> Page
) async throws -> Page {
    if let debounce {
        try await Dependencies.current.clock.sleep(for: debounce)
    }
    try Task.checkCancellation()
    do {
        return try await body(Dependencies.current.client)
    } catch let urlError as URLError where urlError.code == .cancelled {
        throw CancellationError()
    }
}

/// Registers the load every fetch arm shares into `tasks[id]`: fetch the
/// page (with an optional debounce), merge its stories into the entity
/// store, hand the page to `commit`, and mark `status` succeeded.
/// Cancellation is silent (a newer fetch clears loading when it
/// commits); any other error lands on `status`.
///
/// - Parameters:
///   - id: Registry slot for the in-flight load; a prior occupant is
///     cancelled and replaced.
///   - state: The model to mutate.
///   - status: Key path to the `LoadStatus` field carrying this load's
///     success/failure.
///   - tasks: Registry that spawns the work onto the host actor.
///   - debounce: Delay before the fetch, or `nil`.
///   - request: Issues the page fetch.
///   - commit: Records the fetched page (and its story ids) into `state`
///     — a fresh `LoadedStories` for an initial load, `appendPage` for
///     load-more.
/// - Returns: The in-flight `Task`.
@discardableResult
func load(
    _ id: TaskID,
    into state: Model,
    status: ReferenceWritableKeyPath<Model, LoadStatus>,
    tasks: TaskRegistry<TaskID>,
    debounce: Duration? = nil,
    request: @escaping @Sendable (Client) async throws -> Page,
    commit: @escaping (Page, [String]) -> Void
) -> Task<Void, Never> {
    tasks.run(id) {
        do {
            let page = try await fetch(debounce: debounce, body: request)
            try Task.checkCancellation()
            for story in page.stories { state.stories[story.id] = story }
            commit(page, page.stories.map(\.id))
            state[keyPath: status].finishSuccess()
        } catch is CancellationError {
        } catch {
            state[keyPath: status].finishFailure(error.localizedDescription)
        }
    }
}

// MARK: - Production entry (@MainActor, bridged)

/// Builds the core on `MainActor` and returns the ``Core`` handle for the
/// UI to consume. The bridged production entry point: pins `#isolation` to
/// `MainActor`, so the returned handle's `sendMessage` and fetch work run
/// there, and is the only function that crosses JNI.
///
/// Call once at app scope and keep the handle for the process lifetime:
/// iOS holds it as `@State` on the `App`, Android stashes it on
/// `Application` in `onCreate`. App code builds the send capability from
/// the handle with `SendMessageAction(core)`.
///
/// - Returns: The ``Core`` handle.
// SKIP @bridge
@MainActor public func makeAppCore() -> Core {
    makeCore()
}
