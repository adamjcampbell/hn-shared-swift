import Observation

/// Keyed store of in-flight `Task`s that spawns the work it tracks
/// through an injected `spawn` closure (the composition root supplies
/// one bound to its isolation). Non-`Sendable` by design: every capture
/// of it is confined to the region it was built on, which is what
/// serialises `entries` without a lock.
///
/// ``run(_:work:)`` composes the caller's `work` with an
/// identity-guarded vacate into one closure and hands it to `spawn`. The
/// vacate keeps joining honest: a finished task removes its entry only
/// while the slot is still its own, so a replaced task finishing late
/// never clobbers its replacement, and an id with an entry is an id with
/// live work — a caller wanting to resubscribe to (join) an in-flight
/// run reads ``subscript(_:)`` and awaits what it finds rather than
/// starting a duplicate.
///
/// `@Observable` so membership is a watchable test signal: a test reads
/// ``subscript(_:)`` inside `withObservationTracking` (via `waitUntil`)
/// to await a task being registered, replaced (`Task` is `Equatable`),
/// or removed.
@Observable
final class TaskRegistry<ID: Hashable> {
    private var entries: [ID: Task<Void, Never>] = [:]
    @ObservationIgnored private let spawn: (@escaping () async -> Void) -> Task<Void, Never>

    /// - Parameter spawn: Spawns a task running `work` on the host
    ///   isolation the spawner carries. Must enqueue rather than run
    ///   inline (`Task(operation:)`, never `Task.immediate`) — the
    ///   vacate guard registers the task before its body may start.
    init(spawn: @escaping (@escaping () async -> Void) -> Task<Void, Never>) {
        self.spawn = spawn
    }

    /// The in-flight task for `id`, or `nil` when the slot is vacant.
    /// Read-only — mutation goes through ``run(_:work:)`` /
    /// ``cancel(_:)`` so the spawn and vacate bookkeeping can't be
    /// bypassed. An observable read: `waitUntil { tasks[.search] != before }`
    /// suspends until the slot's occupant changes. Reading it to await
    /// the occupant is the join (resubscribe) strategy.
    subscript(id: ID) -> Task<Void, Never>? {
        entries[id]
    }

    /// Cancels the in-flight task for `id` (if any) and spawns `work`
    /// in its place — latest-wins, the debounced-search and
    /// pull-to-refresh semantics. The identity-guarded vacate runs in
    /// the composed work's tail, on the host actor, so a replaced task
    /// finishing late leaves its replacement's slot alone.
    ///
    /// - Parameters:
    ///   - id: Slot the work occupies while in flight.
    ///   - work: The work; a plain closure, bound to the host isolation
    ///     by the spawner.
    /// - Returns: The task now in flight for `id`.
    @discardableResult
    func run(
        _ id: ID,
        work: @escaping () async -> Void
    ) -> Task<Void, Never> {
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
