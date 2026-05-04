import SwiftUI
import AppCore

/// Capability-style action exposed via `@Environment(\.dispatch)`. Mirrors
/// the ergonomic of SwiftUI's `DismissAction`: child views call
/// `dispatch(.someEvent)` without ever holding a reference to `AppModel`.
///
/// The wrapper holds the `AppModel` directly rather than an arbitrary
/// closure so it can implement `Equatable` via `===`. Without that,
/// SwiftUI's reflection-based environment diffing would treat the value
/// as changed on every parent body re-evaluation (closures are neither
/// equatable nor reference-comparable in Swift) and invalidate every
/// descendant reading the key.
///
/// The model is optional so the default environment value is a real
/// no-op (no throwaway `AppModel` allocation) for views rendered outside
/// an installed `\.dispatch` (e.g. previews).
struct AppEventDispatch: Equatable {
    private let model: AppModel?

    init(_ model: AppModel? = nil) {
        self.model = model
    }

    /// Fire-and-forget. Used by tap handlers and `onChange` call sites.
    func callAsFunction(_ event: AppEvent) {
        Task { [model] in await model?.dispatch(event) }
    }

    /// Awaitable. Use from `.refreshable` so the pull-to-refresh spinner
    /// stays visible until the dispatch actually completes.
    func run(_ event: AppEvent) async {
        await model?.dispatch(event)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
    }
}

extension EnvironmentValues {
    @Entry var dispatch: AppEventDispatch = AppEventDispatch()
}
