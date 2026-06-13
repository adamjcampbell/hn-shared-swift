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
/// ``Model`` is non-`Sendable` and never leaves the region its `Core`
/// was built on. Production wraps ``sendMessage`` in a `@MainActor`
/// ``SendMessageAction`` at the app boundary; only ``model`` and
/// ``commands`` cross JNI.
// SKIP @bridgeMembers
public struct Core {
    public let model: Model

    public let commands: AsyncStream<Command>

    /// Applies a `Message` to the model. Non-`Sendable` (it captures the
    /// `Model` and the registry), so every caller is confined to the
    /// region the `Core` was built on. `internal` so app code reaches it
    /// only through the `@MainActor` ``SendMessageAction``; tests call it
    /// directly. Concurrent UI entry points (a fire-and-forget tap plus a
    /// `.refreshable`) serialise at that `@MainActor` boundary, and the
    /// synchronous ``apply(_:to:commands:tasks:)`` keeps each handler's
    /// read-modify-write atomic against actor reentrancy.
    // SKIP @nobridge
    let sendMessage: (Message) async -> Void

    /// Cancels the listener and any in-flight fetch. Production is
    /// process-lifetime and never calls this; tests call it on fixture
    /// exit so the `Task → Model` references release.
    // SKIP @nobridge
    let cancelAll: () -> Void

    /// The registry behind the handle. `internal` for tests, which
    /// observe it (`@Observable`) to wait for fetch work being
    /// registered, replaced, or removed — a synchronisation signal for
    /// steps that leave ``Model`` unchanged. Production code never
    /// touches it; the registry is non-`Sendable`, so any caller is
    /// confined to the host region like ``sendMessage``'s.
    // SKIP @nobridge
    let tasks: TaskRegistry<TaskID>
}

/// Wires the command stream, the search listener, and the send closure
/// over the injected `model` and `tasks`, and returns the ``Core``.
///
/// Pure wiring with no defaults: the composition root supplies both
/// dependencies — the `model` (so the app can launch in a specific
/// state) and the `tasks` registry (whose spawner carries the caller's
/// isolation; see ``makeAppCore`` and the test fixture). `makeCore` is
/// nonisolated and runs on the caller; its non-`Sendable` state stays in
/// that region. `apply`, `applySearchQuery`, and `load` are plain
/// functions.
///
/// - Parameters:
///   - model: The observable state, constructed by the caller.
///   - tasks: The registry, with a spawner bound to the caller's isolation.
/// - Returns: The ``Core`` handle.
func makeCore(
    model: Model,
    tasks: TaskRegistry<TaskID>
) -> Core {
    let state = model
    let (commands, commandsContinuation) = AsyncStream<Command>.makeStream()

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
        cancelAll: { tasks.cancelAll() },
        tasks: tasks
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
///   - tasks: Registry that tracks the in-flight fetch work and owns
///     its cancellation.
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
        debounce: Dependencies.current.searchDebounce
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
/// `nonisolated(nonsending)`, so the post-sleep continuation resumes on
/// the calling task's actor. The sleep rides the real clock; tests
/// control it through the ambient `Dependencies.searchDebounce` amount
/// (`.zero` to run straight through, huge to hold the window open)
/// rather than a fake clock.
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
        try await Task.sleep(for: debounce)
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
///   - tasks: Registry that tracks the in-flight load and owns its
///     cancellation.
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
/// UI to consume. The bridged production entry point: takes the `model`
/// the app constructed (letting it launch in a specific state) and
/// injects a registry whose spawner is statically `@MainActor`, so the
/// returned handle's `sendMessage` and fetch work run there. The only
/// function that crosses JNI.
///
/// Call once at app scope and keep the handle for the process lifetime:
/// iOS holds it as `@State` on the `App`, Android stashes it on
/// `Application` in `onCreate`. App code builds the send capability from
/// the handle with `SendMessageAction(core)`.
///
/// - Parameter model: The observable state, constructed by the app.
/// - Returns: The ``Core`` handle.
// SKIP @bridge
@MainActor public func makeAppCore(model: Model) -> Core {
    // The spawner closure is inferred `@MainActor` (a non-`Sendable`
    // closure in this `@MainActor` function), so `Task { … }` inherits
    // `MainActor` — no annotation or capture. Tests inject an
    // instance-capturing spawner instead; see the test fixture.
    makeCore(model: model, tasks: TaskRegistry { work in Task { await work() } })
}
