import Foundation
import Observation
import HackerNews
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Inner core (isolation-generic)

/// Identities for the in-flight Tasks ``makeCore`` coordinates through
/// a single ``TaskRegistry``.
enum TaskID { case feed, feedMore, search, searchMore, searchListener }

/// The isolation-generic surfaces behind the UI: the observable
/// ``Model``, the one-shot command stream, an async send-message entry,
/// and a teardown hook.
///
/// ``makeCore`` threads `isolation` through `#isolation`, so the host
/// actor owns every mutation — `MainActor` in production (via
/// ``makeUICore``), a `TestActor` in tests. ``Model`` is non-`Sendable`
/// and never leaves that region.
struct Core {
    let model: Model

    let commands: AsyncStream<Command>

    /// Applies a `Message` to the model. Non-`Sendable` — it captures the
    /// `Model` and the task registry — so the type system confines every
    /// caller to the region `makeCore` was formed on, and the body runs
    /// there: `MainActor` in production (via ``makeUICore``), a `TestActor`
    /// in tests. The listener `Task` and the fetch work share that same
    /// isolation, so every `Model` / registry write stays serialised.
    ///
    /// Concurrent UI entry points (a fire-and-forget tap plus a
    /// `.refreshable`) serialise at the `@MainActor` ``SendMessageAction``
    /// that wraps this; the synchronous ``apply(_:to:commands:tasks:isolation:)``
    /// keeps each handler's read-modify-write atomic against actor reentrancy.
    let sendMessage: (Message) async -> Void

    /// Cancels the listener and any in-flight fetch. Production is
    /// process-lifetime and never calls this; tests call it on fixture
    /// exit so the `Task → Model` references release.
    let cancelAll: () -> Void

    /// Debounce window between a `model.searchQuery` write and the
    /// resulting search fetch.
    static let searchDebounce: Duration = .milliseconds(250)
}

/// Composes the inner core: builds the command stream and task
/// registry, spawns the search listener, and returns the ``Core``
/// handle. Each spawned `Task` references `isolation` so it captures the
/// isolated parameter and runs on the host actor; without that reference a
/// `Task` infers `@concurrent` and fails to compile against the
/// non-`Sendable` `Model` capture. (The `sendMessage` closure references it
/// for a different reason — see its definition below.)
///
/// The listener `Task`, the `sendMessage` closure, and `cancelAll` all
/// close over the one local `var tasks`. It stays a captured local
/// rather than a parameter because an escaping closure cannot capture an
/// `inout`; every capture runs in `isolation`'s region, so the
/// non-`Sendable` state stays serialised.
///
/// - Parameters:
///   - model: The observable state; defaults to a fresh ``Model``.
/// - Returns: The inner ``Core`` handle.
func makeCore(
    model: sending Model = Model(),
    isolation: isolated any Actor = #isolation
) -> Core {
    let state = model
    var tasks = TaskRegistry<TaskID>()
    let (commands, commandsContinuation) = AsyncStream<Command>.makeStream()

    tasks[.searchListener] = Task {
        _ = isolation

        for await query in state.searchQueryChanges {
            applySearchQuery(
                query,
                to: state,
                tasks: &tasks
            )
        }
    }

    return Core(
        model: state,
        commands: commands,
        sendMessage: { message in
            // Resolves `#isolation` in `apply` to the host actor; a closure
            // that dropped this would pass `nil` to its isolated parameter.
            _ = isolation

            await apply(
                message,
                to: state,
                commands: commandsContinuation,
                tasks: &tasks
            )?.value
        },
        cancelAll: { tasks.cancelAll() }
    )
}

// MARK: - Message handling

/// Applies a user-driven ``Message`` to `state`: mutates the model in
/// place, yields any ``Command``, and registers in-flight fetch work.
///
/// Synchronous so the `tasks` access never spans a suspension. The
/// `.refresh` / `.loadMore` arms return their spawned `Task` so the
/// caller can `await` its value *outside* the `inout` scope — which is
/// what keeps that await from overlapping the listener's concurrent
/// `tasks` access on the same actor.
///
/// - Parameters:
///   - message: The message to apply.
///   - state: The model to mutate.
///   - commands: Continuation for one-shot UI commands.
///   - tasks: Registry that owns cancellation of in-flight fetches.
/// - Returns: The spawned fetch `Task` for `.refresh` / `.loadMore`
///   (so `.refreshable` can hold its spinner), `nil` otherwise.
@discardableResult
func apply(
    _ message: Message,
    to state: Model,
    commands: AsyncStream<Command>.Continuation,
    tasks: inout TaskRegistry<TaskID>,
    isolation: isolated any Actor = #isolation
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
        tasks[.feedMore] = nil
        state.feedLoadMoreStatus = LoadStatus()
        state.feedInitialStatus.startLoading()

        let task = loadTask(into: state, status: \.feedInitialStatus) {
            try await $0.frontPage(0)
        } commit: { page, ids in
            state.feedLoaded = LoadedStories(
                ids: ids, page: 0, totalPages: page.totalPages, loadedAt: Dependencies.current.date.now
            )
        }
        tasks[.feed] = task
        return task

    case .loadMore where state.searchQuery.isEmpty:
        guard let loaded = state.feedLoaded, loaded.hasMore,
              !state.feedLoadMoreStatus.isLoading else { return nil }
        let next = loaded.nextPage
        state.feedLoadMoreStatus.startLoading()

        let task = loadTask(into: state, status: \.feedLoadMoreStatus) {
            try await $0.frontPage(next)
        } commit: { page, ids in
            state.feedLoaded?.appendPage(ids, totalPages: page.totalPages)
        }
        tasks[.feedMore] = task
        return task

    case .loadMore:
        guard let loaded = state.searchLoaded, loaded.hasMore,
              !state.searchLoadMoreStatus.isLoading else { return nil }
        let query = state.searchQuery
        let next = loaded.nextPage
        state.searchLoadMoreStatus.startLoading()

        let task = loadTask(into: state, status: \.searchLoadMoreStatus) {
            try await $0.search(query, next)
        } commit: { page, ids in
            state.searchLoaded?.appendPage(ids, totalPages: page.totalPages)
        }
        tasks[.searchMore] = task
        return task
    }
}

/// Applies a debounced `model.searchQuery` change: clears search state
/// on an empty query, otherwise marks loading and spawns the search
/// fetch into `tasks[.search]`.
///
/// Synchronous for the same reason as ``apply(_:to:commands:tasks:isolation:)``:
/// the listener invokes it inside its `for await` loop, so it must not
/// hold the `tasks` access across a suspension.
///
/// - Parameters:
///   - query: The current search query.
///   - state: The model to mutate.
///   - tasks: Registry that owns the search fetch's cancellation.
func applySearchQuery(
    _ query: String,
    to state: Model,
    tasks: inout TaskRegistry<TaskID>,
    isolation: isolated any Actor = #isolation
) {
    if query.isEmpty {
        tasks[.search] = nil
        tasks[.searchMore] = nil
        state.searchLoaded = nil
        state.searchInitialStatus = LoadStatus()
        state.searchLoadMoreStatus = LoadStatus()
        return
    }

    tasks[.searchMore] = nil
    // @Observable re-fires on equal writes; skip no-ops during keystroke bursts.
    if state.searchLoadMoreStatus != LoadStatus() {
        state.searchLoadMoreStatus = LoadStatus()
    }
    if !state.searchInitialStatus.isLoading {
        state.searchInitialStatus.startLoading()
    }

    tasks[.search] = loadTask(
        into: state, status: \.searchInitialStatus,
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
/// Carries `isolation` so the debounce sleep and its post-sleep
/// continuation run on the host actor — tests drive a `TestClock` and
/// drain the actor's queue deterministically, which only works if the
/// sleeper resumes there.
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
    isolation: isolated any Actor = #isolation,
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

/// Spawns the load `Task` every fetch arm shares: fetch the page (with
/// an optional debounce), merge its stories into the entity store, hand
/// the page to `commit`, and mark `status` succeeded. Cancellation is
/// silent (a newer fetch clears loading when it commits); any other
/// error lands on `status`.
///
/// - Parameters:
///   - state: The model to mutate.
///   - status: Key path to the `LoadStatus` field carrying this load's
///     success/failure.
///   - debounce: Delay before the fetch, or `nil`.
///   - request: Issues the page fetch.
///   - commit: Records the fetched page (and its story ids) into `state`
///     — a fresh `LoadedStories` for an initial load, `appendPage` for
///     load-more.
/// - Returns: The spawned `Task`.
func loadTask(
    into state: Model,
    status: ReferenceWritableKeyPath<Model, LoadStatus>,
    debounce: Duration? = nil,
    isolation: isolated any Actor = #isolation,
    request: @escaping @Sendable (Client) async throws -> Page,
    commit: @escaping (Page, [String]) -> Void
) -> Task<Void, Never> {
    Task {
        _ = isolation

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

// MARK: - Outer core (@MainActor, bridged)

/// The `@MainActor` surfaces iOS, Android, and the SkipFuse bridge
/// consume: the observable ``Model``, the one-shot command stream, and
/// an `Equatable` send-message capability.
// SKIP @bridgeMembers
@MainActor
public struct UICore {
    public let model: Model
    public let commands: AsyncStream<Command>
    public let sendMessage: SendMessageAction
}

/// Builds the core on `MainActor` and returns the ``UICore`` handle for
/// the UI to consume.
///
/// Call once at app scope and keep the handle for the process lifetime:
/// iOS holds it as `@State` on the `App`, Android stashes it on
/// `Application` in `onCreate`.
///
/// - Returns: A handle bundling the model, the command stream, and the
///   send-message capability.
// SKIP @bridge
@MainActor public func makeUICore() -> UICore {
    let core = makeCore()

    return UICore(
        model: core.model,
        commands: core.commands,
        sendMessage: SendMessageAction(id: ObjectIdentifier(core.model)) { @MainActor in
            await core.sendMessage($0)
        }
    )
}
