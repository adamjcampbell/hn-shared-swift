import Foundation

/// All user-driven mutations flow through this enum.
///
/// On iOS the View calls `appModel.dispatch(.toggleRead(id: ...))`
/// directly. On Android the same event is constructed Swift-side from
/// the matching typed JNI thunk (`appcoreToggleRead(id:)`,
/// `appcoreOpenStory(id:)`, `appcoreRefresh()`) and dispatched through
/// the same `AppModel.dispatch` method. Adding a new mutation case here
/// is the structural change; the cross-platform plumbing then needs a
/// sibling thunk in `AppCoreNative.swift` and a `when` arm in
/// `AppModelHolder.dispatch`.
///
/// `searchQuery` is intentionally *not* an event case. Both platforms
/// drive `state.searchQuery` directly — iOS via `@Bindable` +
/// `$state.searchQuery`, Android via the per-property JNI setter
/// `appcoreSetSearchQuery`. `AppModel`'s long-lived watcher observes
/// `state.searchQuery` and fires the debounced fetch regardless of who
/// wrote it. Events remain the path for command-shaped mutations
/// (toggle, refresh, navigate); per-property setters are the path for
/// continuously-bound primitives.
public enum AppEvent: Sendable, Equatable {
    case toggleRead(id: String)
    case openStory(id: String)
    case refresh
}
