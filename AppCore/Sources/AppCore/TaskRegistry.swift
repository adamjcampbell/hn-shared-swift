/// Anything that can be cancelled. `Task` conforms via its existing
/// `cancel()` method, so the registry can store tasks of any signature
/// without a wrapper at call sites.
protocol Cancellable {
    func cancel()
}

extension Task: Cancellable {}

/// Keyed store of in-flight cancellables with last-write-wins semantics.
///
/// Assigning a new value for an id cancels the prior value for that id
/// (if any). Assigning `nil` cancels without replacement.
///
/// The registry only owns cancellation — callers keep their typed
/// `Task` local to `await` its value.
struct TaskRegistry<ID: Hashable> {
    private var entries: [ID: any Cancellable] = [:]

    subscript(id: ID) -> (any Cancellable)? {
        get { entries[id] }
        set {
            entries[id]?.cancel()
            entries[id] = newValue
        }
    }
}
