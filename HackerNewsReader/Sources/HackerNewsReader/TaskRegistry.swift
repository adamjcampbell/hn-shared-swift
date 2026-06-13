import Observation

/// Keyed store of in-flight `Task`s with cancel-on-replace and
/// identity-guarded vacate. Non-`Sendable` by design: every capture of
/// it is confined to the region it was formed on, which is what
/// serialises `entries` without a lock.
///
/// The registry does not spawn or await work. Callers build their own
/// `Task` literal — directly in an isolated function's body, capturing
/// the isolated parameter — then ``replace(_:with:)`` it in and
/// ``vacate(_:ifStill:)`` from the literal's synchronous tail. The
/// division is load-bearing: a suspending closure passed as a value can
/// resume off the host actor after an internal `await` even when it
/// captures the isolated parameter (TSan-verified on Swift 6.3.1), so a
/// registry that awaited injected work would run its bookkeeping — and
/// the caller's post-await writes — on the global executor. Only code
/// written inside the caller's own capturing literal is reliably pinned.
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

    /// The in-flight task for `id`, or `nil` when the slot is vacant.
    /// Read-only — mutation goes through ``replace(_:with:)`` /
    /// ``vacate(_:ifStill:)`` / ``cancel(_:)`` so the bookkeeping can't
    /// be bypassed. An observable read: `waitUntil { tasks[.search] != before }`
    /// suspends until the slot's occupant changes. Reading it to await
    /// the occupant is the join (resubscribe) strategy.
    subscript(id: ID) -> Task<Void, Never>? {
        entries[id]
    }

    /// Cancels the in-flight task for `id` (if any) and records `task`
    /// in its place — latest-wins, the debounced-search and
    /// pull-to-refresh semantics. Call before the task's body can run
    /// (a `Task { … }` on an actor enqueues, so registering immediately
    /// after creation is safe; an inline-starting `Task.immediate` is
    /// not), so the vacate guard always sees its own registration.
    func replace(_ id: ID, with task: Task<Void, Never>) {
        entries[id]?.cancel()
        entries[id] = task
    }

    /// PROBE: spawns laundered work as the in-flight task for `id`
    /// (latest-wins). The registry needs no isolation of its own — the
    /// `@isolated(any)` value carries its executor, and `Task(operation:)`
    /// enqueues on it (SE-0431). The work's tail should call
    /// ``vacate(_:ifStill:)`` with the returned task.
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
    /// finishing task's own synchronous tail; the identity guard makes a
    /// replaced task finishing late leave its replacement's slot alone.
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
