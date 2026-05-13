import SwiftUI
import AppCore

/// Capability-style action exposed via `@Environment(\.dispatch)`. Mirrors
/// the ergonomic of SwiftUI's `DismissAction`: child views call
/// `dispatch(.someEvent)` without ever holding a reference to `UICore`.
///
/// The wrapper holds the `UICore` directly rather than an arbitrary
/// closure so it can implement `Equatable`. The conformance leans on
/// the app-lifetime invariant that `RootView` constructs exactly one
/// `UICore`, so nil-parity on the held optional uniquely identifies
/// "installed dispatcher" vs "default env value". Without an
/// `Equatable` conformance, SwiftUI's reflection-based environment
/// diffing would treat the value as changed on every parent body
/// re-evaluation (closures are neither equatable nor reference-
/// comparable in Swift) and invalidate every descendant reading the
/// key.
///
/// The core is optional so the default environment value is a real
/// no-op (no throwaway `UICore` allocation) for views rendered outside
/// an installed `\.dispatch` (e.g. previews).
struct AppEventDispatch: Equatable {
    private let core: UICore?

    init(_ core: UICore? = nil) {
        self.core = core
    }

    /// Fire-and-forget. Used by tap handlers and `onChange` call sites.
    @MainActor
    func callAsFunction(_ event: AppEvent) {
        Task { @MainActor [core] in await core?.dispatch(event) }
    }

    /// Awaitable. Use from `.refreshable` so the pull-to-refresh spinner
    /// stays visible until the dispatch actually completes.
    @MainActor
    func run(_ event: AppEvent) async {
        await core?.dispatch(event)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Only one UICore exists per app lifetime, so equality reduces to
        // whether both sides are the installed dispatcher (non-nil) or both
        // are the default env value (nil).
        (lhs.core == nil) == (rhs.core == nil)
    }
}

extension EnvironmentValues {
    @Entry var dispatch: AppEventDispatch = AppEventDispatch()
}
