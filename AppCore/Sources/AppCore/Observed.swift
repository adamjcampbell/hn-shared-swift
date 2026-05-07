import Observation

/// A small `AsyncSequence` that yields the value of a single key path on
/// an `@Observable` reference each time the property changes (and once
/// at iteration start, matching `Observations`' initial-emission
/// semantics).
///
/// Modelled after Swift 6.2's `Observations` (SE-0475) but available on
/// iOS 17+ — `Observations` itself ships in the Swift 6.2 stdlib, which
/// on Apple platforms means iOS 26+. This wraps `withObservationTracking`
/// (iOS 17+) inside an iterator that re-arms on each `next()` call,
/// trading the multi-property closure shape of `Observations` for a
/// single key path.
///
/// **Iteration discipline:** the iterator is non-Sendable. Each `next()`
/// runs on the caller's actor under SE-0461 (`NonisolatedNonsendingByDefault`);
/// the apply closure of `withObservationTracking` reads `root[keyPath:]`
/// synchronously on that actor, and the `@Sendable onChange` callback
/// only resumes a `CheckedContinuation` (no non-Sendable region crossing).
/// This means a `for await` over an `ObservedKeyPath` works cleanly from
/// any single isolation domain (`MainActor`, an `actor`'s executor, a
/// `@MainActor` test) but won't survive being passed across actors —
/// just the way `Observations` constraints work.
///
/// **Cancellation:** `Task.cancel()` on the surrounding task ends the
/// loop. The wait inside `next()` rides on `AsyncStream`'s built-in
/// cancellation handling rather than `withCheckedContinuation` (which
/// is uncancellable), so a view torn down between writes — when no
/// further `willSet` is coming to wake the iterator — exits cleanly
/// instead of hanging.
///
/// **Why not `Observations`:** the `Observations`-shaped equivalent
/// would be `Observations { state.searchQuery }`, which works
/// identically — once iOS 26 is the deployment floor, drop this type
/// and use `Observations` directly. Until then this is the smallest
/// portable shape that gives us the same `for await` ergonomics.
public struct ObservedKeyPath<Root: Observable, Value>: AsyncSequence {
    public typealias Element = Value

    let root: Root
    let keyPath: KeyPath<Root, Value>

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(root: root, keyPath: keyPath)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let root: Root
        let keyPath: KeyPath<Root, Value>
        private var emittedInitial = false

        init(root: Root, keyPath: KeyPath<Root, Value>) {
            self.root = root
            self.keyPath = keyPath
        }

        public mutating func next() async -> Value? {
            if Task.isCancelled { return nil }
            if !emittedInitial {
                emittedInitial = true
                return root[keyPath: keyPath]
            }
            // `apply` runs synchronously on the caller's actor — that's
            // where the read registers as a tracker. `onChange` is
            // `@Sendable`, runs on the registry's executor, and touches
            // only the Sendable `AsyncStream.Continuation`. Re-arming
            // happens implicitly on the next `next()` iteration; we
            // never recurse from inside `onChange`.
            //
            // The wait sits on `for await _ in stream` rather than
            // `withCheckedContinuation` so it's cancellation-aware:
            // `AsyncStream.Iterator.next()` returns nil on the
            // surrounding task's cancellation, which terminates the
            // for-await — even when no `willSet` ever arrives to fire
            // `onChange`. `continuation.finish()` is idempotent, so
            // a willSet racing with cancellation is safe.
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            withObservationTracking {
                _ = root[keyPath: keyPath]
            } onChange: {
                continuation.finish()
            }
            for await _ in stream { }

            if Task.isCancelled { return nil }
            // `withObservationTracking`'s `onChange` fires during the
            // property's `willSet` — *before* the new value has been
            // assigned to `_keyPath`'s backing storage. Yielding twice
            // lets the writer's assignment frame complete (didSet,
            // return) before we read; one yield isn't always enough
            // because `AsyncStream.finish()` from inside `onChange`
            // can resume this iterator earlier in the runtime cycle
            // than the writer's frame finishes. Apple's `Observations`
            // solves the same problem by emitting at "transaction
            // end"; this is the poor-man's version.
            await Task.yield()
            await Task.yield()
            return root[keyPath: keyPath]
        }
    }
}

extension Observable {
    /// Yields `self[keyPath: keyPath]` on iteration start and on every
    /// subsequent `willSet` of the tracked property.
    ///
    ///     for await query in appModel.state.observe(\.searchQuery).dropFirst() {
    ///         await appModel.runFetch(debounce: AppModel.searchDebounce)
    ///     }
    ///
    /// `dropFirst()` skips the iteration-start emission when only
    /// changes matter (e.g. avoiding a duplicate cold-start fetch).
    public func observe<Value>(
        _ keyPath: KeyPath<Self, Value>
    ) -> ObservedKeyPath<Self, Value> {
        ObservedKeyPath(root: self, keyPath: keyPath)
    }
}
