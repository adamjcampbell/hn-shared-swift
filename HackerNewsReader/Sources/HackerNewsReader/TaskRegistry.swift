import Observation

/// Keyed store of in-flight `Task`s that also owns the ability to spawn
/// them.
///
/// `makeCore` injects `spawn` — a closure that creates a `Task` on the
/// host actor — so this class is both the registry and the only path
/// work takes onto that actor. Non-`Sendable` by design: every capture
/// of it is confined to the region it was formed on, which is what
/// serialises `entries` without a lock.
///
/// An entry removes itself when its task finishes, guarded by an
/// identity check so a completed task never clobbers the slot of a
/// replacement that has since taken it over. That self-removal is what
/// keeps ``run(_:strategy:work:)``'s `.joinInFlight` honest: an id with
/// an entry is an id with live work.
///
/// `@Observable` so membership is a watchable signal: tests read
/// ``subscript(_:)`` inside `withObservationTracking` (via `waitUntil`)
/// and wait for a task to be registered, replaced (`Task` is
/// `Equatable`, so identity comparison detects cancel-and-replace), or
/// removed — instead of draining the actor's queue a guessed number of
/// times.
@Observable
final class TaskRegistry<ID: Hashable> {
    /// What ``run(_:strategy:work:)`` does when the id already has an
    /// in-flight task.
    enum Strategy {
        /// Cancel the in-flight task and start `work` in its place.
        /// Latest-wins: debounced search, pull-to-refresh.
        case cancelAndReplace
        /// Return the in-flight task untouched and drop `work` — the
        /// caller awaits (resubscribes to) the existing run instead of
        /// starting a duplicate.
        case joinInFlight
    }

    private var entries: [ID: Task<Void, Never>] = [:]
    @ObservationIgnored private let spawn: (@escaping () async -> Void) -> Task<Void, Never>

    /// The in-flight task for `id`, or `nil` when the slot is vacant.
    /// Read-only — mutation goes through ``run(_:strategy:work:)`` /
    /// ``cancel(_:)`` so the spawn and self-removal bookkeeping can't be
    /// bypassed. An observable read: `waitUntil { tasks[.search] != before }`
    /// suspends until the slot's occupant changes.
    subscript(id: ID) -> Task<Void, Never>? {
        entries[id]
    }

    /// - Parameter spawn: Creates the `Task` for each ``run(_:strategy:work:)``.
    ///   Must enqueue onto the host actor rather than run `work` inline —
    ///   the self-removal guard registers the task before its body may
    ///   start, which holds for `Task { … }` on an actor but not for an
    ///   inline-starting spawn like `Task.immediate`.
    init(spawn: @escaping (@escaping () async -> Void) -> Task<Void, Never>) {
        self.spawn = spawn
    }

    /// Spawns `work` as the in-flight task for `id`, resolving a
    /// collision with the task already in flight per `strategy`.
    ///
    /// - Parameters:
    ///   - id: Slot the work occupies while in flight.
    ///   - strategy: Collision policy; defaults to ``Strategy/cancelAndReplace``.
    ///   - work: The work to run on the host actor.
    /// - Returns: The task now in flight for `id` — the freshly spawned
    ///   one, or the joined existing one under ``Strategy/joinInFlight``.
    @discardableResult
    func run(
        _ id: ID,
        strategy: Strategy = .cancelAndReplace,
        work: @escaping () async -> Void
    ) -> Task<Void, Never> {
        if strategy == .joinInFlight, let inFlight = entries[id] {
            return inFlight
        }
        entries[id]?.cancel()

        var handle: Task<Void, Never>?
        let task = spawn { [self] in
            await work()
            if entries[id] == handle { entries[id] = nil }
        }
        handle = task
        entries[id] = task
        return task
    }

    /// Cancels the in-flight task for `id`, if any.
    func cancel(_ id: ID) {
        entries[id]?.cancel()
        entries[id] = nil
    }

    /// Cancels every in-flight task.
    func cancelAll() {
        for entry in entries.values { entry.cancel() }
        entries.removeAll()
    }
}
