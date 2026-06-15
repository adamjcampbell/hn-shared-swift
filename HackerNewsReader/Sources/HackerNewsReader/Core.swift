import Foundation
import Observation
import HackerNews
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Core (isolation-generic, bridged)

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
    /// `Model` and the fetch ``Tasks``), so every caller is confined to the
    /// region the `Core` was built on. `internal` so app code reaches it
    /// only through the `@MainActor` ``SendMessageAction``; tests call it
    /// directly. Concurrent UI entry points (a fire-and-forget tap plus a
    /// `.refreshable`) serialise at that `@MainActor` boundary, and
    /// ``apply(_:to:commands:tasks:)`` keeps each handler's pre-fetch
    /// read-modify-write before its first `await`, so it stays atomic
    /// against actor reentrancy.
    // SKIP @nobridge
    let sendMessage: (Message) async -> Void

    /// Cancels the search driver and any in-flight fetch. Production is
    /// process-lifetime and never calls this; tests call it on fixture
    /// exit so the `Task → Model` references release.
    // SKIP @nobridge
    let cancelAll: () -> Void
}

/// Wires the command stream, the search driver, and the send closure over
/// the injected `model`, and returns the ``Core``.
///
/// The composition root supplies the `model` (so the app can launch in a
/// specific state) and `spawn`, whose `Task` carries the caller's isolation
/// (see ``makeAppCore`` and the test fixture). `spawn` is the host-actor
/// capability used only where work must run *and mutate the `Model`*: the
/// search driver and the per-query ``applySearch`` it spawns. The fetches
/// don't need it — ``latest(_:on:debounce:_:)`` brokers only `Sendable`
/// values, so its in-flight `Task` runs the fetch off the host actor while
/// the caller commits the result on it. `makeCore` is nonisolated and runs
/// on the caller; its non-`Sendable` ``Tasks`` stays in that region.
///
/// - Parameters:
///   - model: The observable state, constructed by the caller.
///   - spawn: Spawns a `Task` bound to the caller's isolation, for work
///     that mutates the `Model` on the host actor.
/// - Returns: The ``Core`` handle.
func makeCore(
    model: Model,
    spawn: @escaping (@escaping () async -> Void) -> Task<Void, Never>
) -> Core {
    let state = model
    let (commands, commandsContinuation) = AsyncStream<Command>.makeStream()
    // The in-flight fetches: one slot for the feed (refresh + feed
    // load-more), one for search (reload + search load-more).
    let tasks = Tasks()

    let consumer = spawn {
        await runSearch(state, tasks: tasks, spawn: spawn)
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
            )
        },
        cancelAll: {
            consumer.cancel()
            cancel(\.feed, on: tasks)
            cancel(\.search, on: tasks)
        }
    )
}

// MARK: - Message handling

/// Applies a user-driven ``Message`` to `state`: mutates the model in
/// place, yields any ``Command``, and awaits any fetch the message
/// triggers.
///
/// Caller-following (`nonisolated(nonsending)`, the package default), so
/// it runs on whatever actor calls it — always the host actor, because
/// every caller closes over the non-`Sendable` `state` — and resumes there
/// after each `await`. Each fetch arm performs its read-modify-write
/// synchronously *before* the first `await`, so it stays atomic against
/// actor reentrancy; the post-fetch commit runs back on the host actor,
/// guarded against staleness by the slot's cancel-and-replace (a
/// superseded fetch throws `CancellationError` and commits nothing). The
/// `.refresh` / `.loadMore` arms await their fetch so `.refreshable` can
/// hold its spinner.
///
/// - Parameters:
///   - message: The message to apply.
///   - state: The model to mutate.
///   - commands: Continuation for one-shot UI commands.
///   - tasks: The fetch slots. The feed slot is shared by refresh and feed
///     load-more (a refresh cancels an in-flight load-more); the search
///     slot by the reload and search load-more (a new query cancels an
///     in-flight load-more).
func apply(
    _ message: Message,
    to state: Model,
    commands: AsyncStream<Command>.Continuation,
    tasks: Tasks
) async {
    switch message {

    case .toggleRead(let id):
        if state.readIds.contains(id) {
            state.readIds.remove(id)
        } else {
            state.readIds.insert(id)
        }

    case .openStory(let id):
        guard let story = state.stories[id] else { return }
        state.readIds.insert(id)
        if let url = story.url {
            commands.yield(.presentURL(value: url))
        }

    case .refresh:
        state.feedLoadMoreStatus = LoadStatus()
        state.feedInitialStatus.startLoading()
        await load(into: state, status: \.feedInitialStatus) {
            try await latest(\.feed, on: tasks) {
                try await Dependencies.current.client.frontPage(0)
            }
        } commit: { page in
            state.feedLoaded = LoadedStories(
                ids: page.stories.map(\.id), page: 0,
                totalPages: page.totalPages, loadedAt: Dependencies.current.date.now
            )
        }

    case .loadMore where state.searchQuery.isEmpty:
        // `!feedInitialStatus.isLoading` yields to an in-flight refresh, so a
        // load-more never cancels the reload it shares the `feed` slot with.
        guard let loaded = state.feedLoaded, loaded.hasMore,
              !state.feedLoadMoreStatus.isLoading,
              !state.feedInitialStatus.isLoading else { return }
        let next = loaded.nextPage
        state.feedLoadMoreStatus.startLoading()
        await load(into: state, status: \.feedLoadMoreStatus) {
            try await latest(\.feed, on: tasks) {
                try await Dependencies.current.client.frontPage(next)
            }
        } commit: { page in
            state.feedLoaded?.appendPage(page.stories.map(\.id), totalPages: page.totalPages)
        }

    case .loadMore:
        guard let loaded = state.searchLoaded, loaded.hasMore,
              !state.searchLoadMoreStatus.isLoading,
              !state.searchInitialStatus.isLoading else { return }
        let query = state.searchQuery
        let next = loaded.nextPage
        state.searchLoadMoreStatus.startLoading()
        await load(into: state, status: \.searchLoadMoreStatus) {
            try await latest(\.search, on: tasks) {
                try await Dependencies.current.client.search(query, next)
            }
        } commit: { page in
            state.searchLoaded?.appendPage(page.stories.map(\.id), totalPages: page.totalPages)
        }
    }
}

/// The long-lived search driver: the one host-isolated `Task` the ``Core``
/// spawns. Binding-driven — the search field writes `model.searchQuery`,
/// whose `didSet` feeds this loop — it spawns the latest ``applySearch``
/// per query change. Spawning rather than awaiting keeps the loop reading
/// the next keystroke while a reload is in flight; the `search` slot does
/// the cancel-and-replace, so the driver does not cancel the prior task
/// itself. It holds only the most recent, to cancel on teardown.
///
/// - Parameters:
///   - state: The model to mutate.
///   - tasks: The fetch slots, shared with the search reload and load-more.
///   - spawn: Spawns each ``applySearch`` on the host actor (so it may
///     commit), with a `Task` bound to the caller's isolation.
func runSearch(
    _ state: Model,
    tasks: Tasks,
    spawn: @escaping (@escaping () async -> Void) -> Task<Void, Never>
) async {
    var pending: Task<Void, Never>?
    defer { pending?.cancel() }

    for await query in state.searchQueryChanges {
        pending = spawn { await applySearch(query, to: state, tasks: tasks) }
    }
}

/// Applies a `model.searchQuery` change — the binding-driven analogue of an
/// ``apply`` fetch arm. Clears search state on an empty query; otherwise
/// marks loading and runs the latest reload through the shared `search`
/// slot (debounced), which cancels any in-flight search load-more.
///
/// Spawned per query by ``runSearch`` (so the driver never blocks) and
/// caller-following, so it commits the `Model` on the host actor. Latest
/// wins by ordering, not by a held handle: the per-query tasks `runSearch`
/// spawns begin in creation order on the host actor (SE-0431), so they
/// claim the `search` slot in query order and only the last (newest) one
/// delivers. The invariant is unenforced by types — the slot is claimed in
/// the task's synchronous head, before the first real suspension inside
/// ``latest(_:on:debounce:_:)``, the spawned closure stays
/// host-actor-isolated, and priority stays uniform.
///
/// - Parameters:
///   - query: The current search query.
///   - state: The model to mutate.
///   - tasks: The fetch slots, shared with the search load-more.
func applySearch(_ query: String, to state: Model, tasks: Tasks) async {
    if query.isEmpty {
        cancel(\.search, on: tasks)
        state.searchLoaded = nil
        state.searchInitialStatus = LoadStatus()
        state.searchLoadMoreStatus = LoadStatus()
        return
    }

    // @Observable re-fires on equal writes; skip no-ops during keystroke bursts.
    if state.searchLoadMoreStatus != LoadStatus() {
        state.searchLoadMoreStatus = LoadStatus()
    }
    if !state.searchInitialStatus.isLoading {
        state.searchInitialStatus.startLoading()
    }

    await load(into: state, status: \.searchInitialStatus) {
        try await latest(\.search, on: tasks, debounce: Dependencies.current.searchDebounce) {
            try await Dependencies.current.client.search(query, 0)
        }
    } commit: { page in
        state.searchLoaded = LoadedStories(
            ids: page.stories.map(\.id), page: 0,
            totalPages: page.totalPages, loadedAt: Dependencies.current.date.now
        )
    }
}

/// Runs `fetch`, merges its stories into the entity store, hands the page to
/// `commit`, and marks `status` succeeded. Cancellation is silent (a newer
/// fetch superseded this one — the slot threw `CancellationError`); any
/// other error lands on `status`.
///
/// Caller-following, so the commit runs back on the host actor the caller
/// called from. `fetch` is a ``latest(_:on:debounce:_:)`` call, so the
/// latest-wins slot is hidden inside it — `load` never names it.
///
/// - Parameters:
///   - state: The model to mutate.
///   - status: Key path to the `LoadStatus` carrying this load's outcome.
///   - fetch: The latest-wins page fetch.
///   - commit: Records the fetched page into `state` — a fresh
///     `LoadedStories` for an initial load, `appendPage` for load-more.
func load(
    into state: Model,
    status: ReferenceWritableKeyPath<Model, LoadStatus>,
    fetch: () async throws -> Page,
    commit: (Page) -> Void
) async {
    do {
        let page = try await fetch()
        for story in page.stories { state.stories[story.id] = story }
        commit(page)
        state[keyPath: status].finishSuccess()
    } catch is CancellationError {
    } catch {
        state[keyPath: status].finishFailure(error.localizedDescription)
    }
}

// MARK: - Production entry (@MainActor, bridged)

/// Builds the core on `MainActor` and returns the ``Core`` handle for the
/// UI to consume. The bridged production entry point: takes the `model`
/// the app constructed (letting it launch in a specific state) and injects
/// a spawner whose `Task` is statically `@MainActor`, so the search driver
/// and its reloads commit there. The only function that crosses JNI.
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
    // closure in this `@MainActor` function), so its `Task { … }` inherits
    // `MainActor` — no annotation or capture — and the driver and its
    // reloads commit there. Tests inject an instance-capturing spawner
    // instead; see the test fixture.
    makeCore(model: model, spawn: { work in Task { await work() } })
}
