import Foundation
import HackerNews
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Core's in-flight fetches: one ``Task`` slot per fetch surface, and
/// nothing more. `feed` holds the latest feed fetch (the refresh and the
/// feed load-more share it); `search` holds the latest search fetch (the
/// reload and the search load-more share it). Sharing one slot per surface
/// is what lets a refresh, or a new query, supersede the load-more it
/// races with.
///
/// Non-`Sendable` and held on the host actor the `Core` was built on, so
/// every read and write of a slot is a synchronous step on that actor and
/// the cancel-and-replace needs no lock and no actor hop. This is only the
/// data; the operations live next door as free functions
/// (``latest(_:on:debounce:_:)`` and ``cancel(_:on:)``).
final class Tasks {
    var feed: Task<Page, Error>?
    var search: Task<Page, Error>?
}

/// Runs `work` as the latest occupant of `slot`, cancelling whatever was
/// in flight there. The slot is claimed synchronously, before the first
/// suspension, so concurrent callers on one actor claim it in creation
/// order and only the last delivers.
///
/// Latest-wins is enforced at *delivery*, not by cancellation alone:
/// `Task.cancel()` only requests cooperative cancellation, so work whose
/// round-trip finishes before the cancel is observed would otherwise hand
/// its value to a caller that has already been superseded. The post-await
/// occupant check closes that race — a superseded caller throws
/// `CancellationError` regardless of whether its work honoured the cancel —
/// so callers can commit unconditionally without a staleness guard of
/// their own.
///
/// - Parameters:
///   - slot: Key path to the task slot this call occupies.
///   - root: The registry holding the slot.
///   - debounce: Delay before `work` runs, a reload rate-limit, or `nil`.
///   - work: The async fetch to run, latest-wins.
/// - Returns: The value `work` produces.
/// - Throws: Whatever `work` throws; `CancellationError` if this call is
///   superseded or cancelled (a `URLError(.cancelled)` is normalised to it).
@discardableResult
func latest<Root: AnyObject, Value: Sendable>(
    _ slot: ReferenceWritableKeyPath<Root, Task<Value, Error>?>,
    on root: Root,
    debounce: Duration? = nil,
    _ work: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    root[keyPath: slot]?.cancel()
    let task = Task {
        if let debounce { try await Task.sleep(for: debounce) }
        return try await work()
    }
    root[keyPath: slot] = task
    let value: Value
    do {
        value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    } catch let urlError as URLError where urlError.code == .cancelled {
        throw CancellationError()
    }
    guard root[keyPath: slot] == task else { throw CancellationError() }
    return value
}

/// Cancels the task in `slot` (if any) and empties it.
///
/// - Parameters:
///   - slot: Key path to the task slot to clear.
///   - root: The registry holding the slot.
func cancel<Root: AnyObject, Value>(
    _ slot: ReferenceWritableKeyPath<Root, Task<Value, Error>?>,
    on root: Root
) {
    root[keyPath: slot]?.cancel()
    root[keyPath: slot] = nil
}
