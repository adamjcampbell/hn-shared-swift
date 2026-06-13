import Observation

/// Keyed store of in-flight `Task`s that spawns the work it tracks
/// through one injected `spawn`, formed where the host isolation is in
/// scope — `makeCore` captures its isolated parameter into the spawner
/// once, and every ``run(_:work:)`` call site stays a plain closure.
/// Non-`Sendable` by design: every capture of it is confined to the
/// region it was formed on, which is what serialises `entries` without
/// a lock.
///
/// Carried isolation is the load-bearing property. Work typed
/// `nonisolated(nonsending)` runs on its *caller's* isolation, which
/// evaporated off-actor when a calling chain lost its pin; the spawner
/// wraps work and epilogue in an `@isolated(any)` operation
/// (``inheritingIsolation(_:)``) that owns its executor, so
/// `Task(operation:)` runs — and resumes — them on the actor the
/// spawner was formed on (SE-0431). If the wrapper's inheritance ever
/// failed, its `@Sendable` requirement could not legalise the
/// non-`Sendable` captures and the spawner would not compile.
///
/// The vacate guard in the spawn's epilogue keeps joining honest: a
/// finished task removes its entry only while the slot is still its
/// own, so a replaced task finishing late never clobbers its
/// replacement, and an id with an entry is an id with live work — a
/// caller wanting to resubscribe to (join) an in-flight run reads
/// ``subscript(_:)`` and awaits what it finds instead of starting a
/// duplicate.
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
    @ObservationIgnored private let spawn: (
        _ work: @escaping () async -> Void,
        _ epilogue: @escaping () -> Void
    ) -> Task<Void, Never>

    /// - Parameter spawn: Spawns a task that awaits `work` and then
    ///   calls the synchronous `epilogue`, both bound to the host
    ///   isolation the spawner carries. Must enqueue rather than run
    ///   inline (`Task(operation:)`, never `Task.immediate`) — the
    ///   vacate guard registers the task before its body may start.
    init(
        spawn: @escaping (
            _ work: @escaping () async -> Void,
            _ epilogue: @escaping () -> Void
        ) -> Task<Void, Never>
    ) {
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
    /// pull-to-refresh semantics. The identity-guarded vacate runs as
    /// the spawn's epilogue, on the host isolation, so a replaced task
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
        let task = spawn(work) { [self] in
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
