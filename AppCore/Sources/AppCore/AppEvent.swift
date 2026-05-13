import Foundation

/// All user-driven mutations flow through this enum. Both platforms
/// call `appCore.sendEvent(.toggleRead(id: ...))` directly — iOS as a
/// SwiftUI Button action, Android from a Composable launching a
/// coroutine on the bridged `suspend fun sendEvent`.
///
/// `searchQuery` is intentionally *not* an event case. Both platforms
/// drive `state.searchQuery` directly — iOS via `@Bindable` +
/// `$state.searchQuery`, Android via the bridged property setter
/// (`state.searchQuery = it`). `AppCoreActor.run` consumes
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
