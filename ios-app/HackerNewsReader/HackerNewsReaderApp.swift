import SwiftUI
import HackerNewsReader

@main
struct HackerNewsReaderApp: App {
    @State private var core = makeAppCore(model: Model())

    var body: some Scene {
        WindowGroup {
            RootView(core: core)
        }
    }
}
