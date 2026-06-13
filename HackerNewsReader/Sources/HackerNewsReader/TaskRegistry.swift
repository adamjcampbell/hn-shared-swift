import Observation

/// Keyed store of in-flight `Task`s that spawns the work it tracks
/// through one injected `spawn`, formed where the host isolation is in
/// scope — `makeCore` captures its isolated parameter into the spawner
/// once, and every ``run(_:work:)`` call site stays a plain closure.
/// Non-`Sendable` by design: every capture of it is confined to the
/// region it was formed on, which is what serialises `entries` without
/// a lock.
///
/// ``run(_:work:)`` composes the caller's `work` with the
/// identity-guarded vacate into one closure and hands it to `spawn`.
/// `makeCore` builds `spawn` as a `Task { _ = isolation; await work() }`
/// literal that inherits the host actor (SE-0420), so the work — and the
/// vacate composed into its tail — runs and resumes there. (An
/// instance-isolated continuation resuming off-executor after an
/// internal `await` was a Swift 6.3 compiler bug, [swiftlang/swift#88993],
/// fixed in 6.4, which this package targets. See ADR-0024.)
///
/// The vacate guard keeps joining honest: a finished task removes its
/// entry only while the slot is still its own, so a replaced task
/// finishing late never clobbers its replacement, and an id with an
/// entry is an id with live work — a caller wanting to resubscribe to
/// (join) an in-flight run reads ``subscript(_:)`` and awaits what it
/// finds instead of starting a duplicate.
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
