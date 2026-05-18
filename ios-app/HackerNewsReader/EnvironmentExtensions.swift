import SwiftUI
import HackerNewsReader

/// Capability-action key for the cross-platform `SendAppEvent`. The
/// default value's underlying `AppCore` is `nil`, so calls are no-ops
/// in previews and any view rendered outside an installed
/// `\.sendEvent`.
extension EnvironmentValues {
    @Entry var sendEvent: SendAppEvent = SendAppEvent()
}
