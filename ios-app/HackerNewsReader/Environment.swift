import SwiftUI
import HackerNewsReader

extension EnvironmentValues {
    /// Capability action for dispatching `Message`s — defaults to
    /// a no-op so calls in previews are safe.
    @Entry var sendMessage: SendMessageAction = SendMessageAction()
}
