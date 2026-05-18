import Foundation

/// All user-driven mutations flow through this enum. Both platforms
/// route through the `SendAppEvent` returned inside `AppCoreHandle`:
/// iOS reads it via `@Environment(\.sendEvent)` and calls
/// `sendEvent(.toggleRead(id:))` (SwiftUI `DismissAction`-style
/// `callAsFunction`); Android holds the handle on its `Application`
/// and calls `core.sendEvent.send(AppEvent.toggleRead(id))`.
///
/// `searchQuery` is intentionally *not* an event case. Both platforms
/// drive `state.searchQuery` directly — iOS via `@Bindable` +
/// `$state.searchQuery`, Android via the bridged property setter
/// (`state.searchQuery = it`). `AppCore`'s listener consumes
/// `state.searchQueryChanges` and fires the debounced fetch
/// regardless of which platform wrote it. Events remain the path for
/// command-shaped mutations (toggle, refresh, navigate); direct property
/// setters are the path for continuously-bound primitives.
// SKIP @bridge
public enum AppEvent: Sendable, Equatable {
    case toggleRead(id: String)
    case openStory(id: String)
    case refresh
    case loadMore
}
