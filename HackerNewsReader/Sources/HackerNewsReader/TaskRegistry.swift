import Observation

/// Keyed store of in-flight `Task`s that spawns the work it tracks:
/// ``run(_:_:)`` takes a `Sendable` `@isolated(any)` value (built with
/// ``inheritingIsolation(_:)``) and enqueues it on the isolation the
/// value carries — the registry itself needs no isolation, no injected
/// spawner, and no `inout` threading. Non-`Sendable` by design: every
/// capture of it is confined to the region it was formed on, which is
/// what serialises `entries` without a lock.
///
/// Carried isolation is the load-bearing property. Work typed
/// `nonisolated(nonsending)` runs on its *caller's* isolation, which
/// evaporated off-actor when a calling chain lost its pin; an
/// `@isolated(any)` value owns its executor, so `Task(operation:)`
/// runs — and resumes — it on the actor it was formed on (SE-0431).
///
/// The vacate guard keeps joining honest: a finished task removes its
/// entry only while the slot is still its own (the work's tail calls
/// ``vacate(_:ifStill:)``), so a replaced task finishing late never
/// clobbers its replacement, and an id with an entry is an id with
/// live work — a caller wanting to resubscribe to (join) an in-flight
/// run reads ``subscript(_:)`` and awaits what it finds instead of
/// starting a duplicate.
///
/// `@Observable` so membership is a watchable signal: tests read
/// ``subscript(_:)`` inside `withObservationTracking` (via `waitUntil`)
/// and wait for a task to be registered, replaced (`Task` is
/// `Equatable`, so identity comparison detects cancel-and-replace), or
/// removed — instead of draining the actor's queue a guessed number of
/// times.
@Observable
final class TaskRegistry<ID: Hashable> {
    private var entries: [ID: Task<Void, Never>] = [:]

    /// The in-flight task for `id`, or `nil` when the slot is vacant.
    /// Read-only — mutation goes through ``run(_:_:)`` /
    /// ``vacate(_:ifStill:)`` / ``cancel(_:)`` so the bookkeeping can't
    /// be bypassed. An observable read: `waitUntil { tasks[.search] != before }`
    /// suspends until the slot's occupant changes. Reading it to await
    /// the occupant is the join (resubscribe) strategy.
    subscript(id: ID) -> Task<Void, Never>? {
        entries[id]
    }

    /// Cancels the in-flight task for `id` (if any) and spawns `work`
    /// in its place — latest-wins, the debounced-search and
    /// pull-to-refresh semantics. The task enqueues on the isolation
    /// `work` carries and is recorded before its body can run, so the
    /// vacate guard always sees its own registration.
    ///
    /// - Parameters:
    ///   - id: Slot the work occupies while in flight.
    ///   - work: The work, carrying its own isolation; its tail should
    ///     call ``vacate(_:ifStill:)`` with the returned task.
    /// - Returns: The task now in flight for `id`.
    @discardableResult
    func run(
        _ id: ID,
        _ work: @Sendable @escaping @isolated(any) () async -> Void
    ) -> Task<Void, Never> {
        entries[id]?.cancel()
        let task = Task(operation: work)
        entries[id] = task
        return task
    }

    /// Vacates `id` if `task` is still its occupant. Call from the
    /// finishing work's own tail; the identity guard makes a replaced
    /// task finishing late leave its replacement's slot alone.
    func vacate(_ id: ID, ifStill task: Task<Void, Never>?) {
        if entries[id] == task { entries[id] = nil }
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
