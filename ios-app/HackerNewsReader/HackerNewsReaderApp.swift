import SwiftUI
import HackerNewsReader

@main
struct HackerNewsReaderApp: App {
    @State private var core = makeCore()

    var body: some Scene {
        WindowGroup {
            RootView(core: core)
        }
    }
}
