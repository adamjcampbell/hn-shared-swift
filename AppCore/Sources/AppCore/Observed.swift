import Foundation
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
/// loop. The wait inside `next()` is `withCheckedContinuation` wrapped
/// in `withTaskCancellationHandler` — when the surrounding task is
/// cancelled, `onCancel` fires and resumes the continuation directly,
/// so a view torn down between writes (no further `willSet` coming to
/// wake the iterator) exits cleanly instead of hanging on an
/// uncancellable continuation. A `_ResumeOnce` coordinator (defined
/// below) guarantees the `onChange`/`onCancel` race resumes the
/// continuation exactly once.
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
            // `@Sendable`, runs on the registry's executor, and only
            // signals the `_ResumeOnce` coordinator (no non-Sendable
            // capture). Re-arming happens implicitly on the next
            // `next()` iteration; we never recurse from inside
            // `onChange`.
            //
            // `withTaskCancellationHandler` makes the wait
            // cancellation-aware: a view torn down between writes
            // (no further `willSet` to fire `onChange`) calls
            // `onCancel` which resumes the continuation directly. The
            // `_ResumeOnce` coordinator guarantees the
            // `onChange`/`onCancel` race resumes the
            // `CheckedContinuation` exactly once — `CheckedContinuation`
            // traps on double-resume, so the single-resume invariant
            // is load-bearing.
            let signal = _ResumeOnce()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    signal.setContinuation(cont)
                    withObservationTracking {
                        _ = root[keyPath: keyPath]
                    } onChange: {
                        signal.resume()
                    }
                    // Cover the gap between the entry-of-`next()`
                    // cancellation check and observation-tracker
                    // registration: if cancellation slipped in, fire
                    // the resume now so we don't block.
                    if Task.isCancelled {
                        signal.resume()
                    }
                }
            } onCancel: {
                signal.resume()
            }

            if Task.isCancelled { return nil }
            // `withObservationTracking`'s `onChange` fires during the
            // property's `willSet` — *before* the new value has been
            // assigned to `_keyPath`'s backing storage. One
            // `Task.yield()` after the suspension lets the writer's
            // assignment frame complete (didSet, return) before we
            // read; the one-yield is sufficient because
            // `cont.resume()` queues resumption on the awaiting
            // task's executor (cooperative with the writer on the
            // same actor). Apple's `Observations` solves the same
            // problem by emitting at "transaction end"; this is the
            // poor-man's version.
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

/// Coordinates a single-resume `CheckedContinuation<Void, Never>` shared
/// between `withObservationTracking`'s `@Sendable onChange` callback and
/// `withTaskCancellationHandler`'s `@Sendable onCancel` callback. Either
/// path may fire first — whichever does resumes the continuation; the
/// other is a no-op. `CheckedContinuation` traps on double-resume, so
/// the single-resume invariant is load-bearing.
///
/// **`@unchecked Sendable` rationale:** Swift 6 stdlib's
/// `Synchronization.Mutex` is iOS 18+ and `os.OSAllocatedUnfairLock` is
/// Apple-only. `Foundation.NSLock` is the lowest-common-denominator
/// thread-safe primitive that compiles on Apple platforms *and* on
/// swift-corelibs-foundation (the Android target's Foundation), but
/// `NSLock` itself doesn't conform to `Sendable`. The wrapper here holds
/// only `NSLock` (thread-safe), a `Bool`, and an
/// `Optional<CheckedContinuation>` (Sendable), and mutates them only
/// under the lock — the conformance is safe in practice; the
/// `@unchecked` is purely a tooling-gap workaround. Drop in favour of
/// `Synchronization.Mutex` once iOS 18 is the deployment floor.
///
/// This is the second documented exception to the "no `@unchecked
/// Sendable` in `AppCore/Sources/`" rule (alongside `JavaInterop.swift`).
private final class _ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func setContinuation(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        if resumed {
            lock.unlock()
            cont.resume()
            return
        }
        continuation = cont
        lock.unlock()
    }

    func resume() {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}
