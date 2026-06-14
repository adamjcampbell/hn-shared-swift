/// A single-slot, latest-wins async operation for one fetch surface
/// (the feed, or a search load-more): each call cancels any operation
/// still in flight and runs the new one in its place. A superseded
/// caller's `await` throws `CancellationError`.
///
/// Brokers only `Sendable` values — the request closure and its `Value`
/// — so it needs no host isolation and spawns no isolation-bound work:
/// the in-flight `Task` runs the fetch wherever, and the caller (which
/// stays on the host actor) commits the `Value` it returns. Non-`Sendable`
/// and host-actor-confined, like the registry it replaces: every access
/// to `inFlight` is a synchronous step on the host actor, so the
/// cancel-and-swap needs no lock and no actor hop.
///
/// Latest-wins is enforced at *delivery*, not by cancellation alone:
/// `cancel()` only requests cooperative cancellation, so a fetch whose
/// round-trip completes before the cancel is observed would otherwise
/// hand its value to a caller that has already been superseded. The
/// post-await `inFlight == task` check closes that race — a superseded
/// caller throws `CancellationError` regardless of whether its work
/// honoured the cancel — so callers (`load`) can commit unconditionally
/// without their own staleness guard.
final class Latest<Value: Sendable> {
    /// The current occupant. After a successful call it retains that
    /// call's completed `Task` (holding a `Sendable` `Value`, no `Model`
    /// capture — so no retain cycle); the slot is reclaimed on the next
    /// call or by ``cancel()``.
    private var inFlight: Task<Value, Error>?

    /// Cancels the in-flight operation (if any) and runs `work` in its
    /// place. Returns `work`'s value, or rethrows its error;
    /// `CancellationError` if a newer call (or ``cancel()``) supersedes
    /// this one before it returns, or if the calling task is cancelled.
    ///
    /// - Parameter work: The async operation to run, latest-wins.
    /// - Returns: The value `work` produces.
    /// - Throws: Whatever `work` throws, or `CancellationError`.
    @discardableResult
    func callAsFunction(_ work: @Sendable @escaping () async throws -> Value) async throws -> Value {
        inFlight?.cancel()
        let task = Task { try await work() }
        inFlight = task
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        // Back on the host actor: if a newer call (or `cancel()`) replaced
        // us while `work` was completing, our value is stale — report
        // cancellation so the caller commits nothing.
        guard inFlight == task else { throw CancellationError() }
        return value
    }

    /// Cancels the in-flight operation and empties the slot.
    func cancel() {
        inFlight?.cancel()
        inFlight = nil
    }
}
