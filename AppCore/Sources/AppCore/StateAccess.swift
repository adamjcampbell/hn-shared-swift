import Foundation

/// Gives `AppCoreActor` mediated access to a non-`Sendable` `AppState`
/// that lives on a shell (`AppCore` for production, `TestCore` for
/// tests). The shim is itself `Sendable` so it can be installed on
/// `AppCoreActor`'s actor-isolated state via the shell's
/// `handler.assumeIsolated { handler.state = … }` block.
///
/// Reads and writes go through the wrapped `any StateMutator`. Each
/// concrete mutator (one per shell type) calls into the shell's
/// isolation via `assumeIsolated`, where `AppState` is reachable.
/// The non-`@Sendable` closure parameters on `StateMutator`'s methods
/// mean keypath captures inside the shim's subscripts don't need to
/// be `Sendable` — sidestepping the `@unchecked Sendable` workarounds
/// the closure-based design needed.
@dynamicMemberLookup
struct StateAccess: Sendable {
    private let mutator: any StateMutator

    init(_ mutator: any StateMutator) {
        self.mutator = mutator
    }

    /// Read any Sendable property of AppState via key path.
    /// `state.searchQuery`, `state.feed.loadedHits?.loadedAt`, etc.
    ///
    /// **Writes go through `callAsFunction`** (`state { $0.foo = bar }`)
    /// rather than a writable subscript. A writable subscript would
    /// need `sending` on the keypath parameter, which conflicts with
    /// Swift's `_modify` accessor synthesis (the keypath is used by
    /// both the implicit get and set, but `sending` consumes it).
    subscript<T: Sendable>(dynamicMember keyPath: sending KeyPath<AppState, T>) -> T {
        mutator.read { $0[keyPath: keyPath] }
    }

    /// Compound mutation: `state { s in … }`. Use when a single
    /// transaction needs to read multiple fields, call a mutating
    /// helper (e.g. `state.upsert(page)`), or write several fields
    /// in one acquire round-trip.
    func callAsFunction(_ work: sending (AppState) -> Void) {
        mutator.apply(work)
    }

    /// Compound read returning a Sendable value. Use when the read
    /// needs to compose multiple AppState properties or call a
    /// method that returns a Sendable result.
    func read<T: Sendable>(_ work: sending (AppState) -> T) -> T {
        mutator.read(work)
    }
}

/// The conformance contract for shell-side state access. Conforming
/// types are `Sendable` (so they can cross into `AppCoreActor`'s
/// isolation) and `AnyObject` (so the existential `any StateMutator`
/// can be erased without `Self`-constraint trouble). Method parameters
/// are deliberately *not* `@Sendable` — the method runs `work`
/// synchronously inside the conformer's isolation, so closure captures
/// inside `work` don't need to be `Sendable`.
protocol StateMutator: AnyObject, Sendable {
    func apply(_ work: sending (AppState) -> Void)
    func read<T: Sendable>(_ work: sending (AppState) -> T) -> T
}

/// Default for `AppCoreActor.state` between actor construction and
/// the shell installing the real mutator. Methods invoked before
/// installation become no-ops (`apply`) or trap (`read`) — the
/// installation happens synchronously in `AppCore.init` for
/// production, so the window is unobservable there. `TestCore`'s
/// async init `await`s past the install before returning.
final class NoopMutator: StateMutator {
    func apply(_ work: sending (AppState) -> Void) {}
    func read<T: Sendable>(_ work: sending (AppState) -> T) -> T {
        fatalError("StateAccess.read called before mutator was installed")
    }
}

/// Production mutator. Pinned to `@MainActor`, so the class is
/// implicitly `Sendable`. Methods are `nonisolated` and use
/// `MainActor.assumeIsolated` to reach `appState` — runtime no-op
/// because `AppCoreActor`'s executor is borrowed from MainActor.
@MainActor
final class MainActorMutator: StateMutator {
    let appState: AppState
    init(_ appState: AppState) { self.appState = appState }

    nonisolated func apply(_ work: sending (AppState) -> Void) {
        MainActor.assumeIsolated {
            work(self.appState)
        }
    }

    nonisolated func read<T: Sendable>(_ work: sending (AppState) -> T) -> T {
        MainActor.assumeIsolated {
            work(self.appState)
        }
    }
}
