#if canImport(Android)
import Foundation
import Observation
import Testing
import AppCoreAndroid

@Observable
private final class Counter {
    var count: Int = 0
    var other: Int = 0
}

@Suite("withObservationTracking mechanics")
struct ObservationScopeTests {
    /// The fused `appcoreObserveGet*` thunks rely on onChange firing exactly
    /// once per registration. Re-registration is the composable's
    /// responsibility via the remember(counter.intValue) → appcoreObserveGet* cycle.
    @Test("onChange fires once — further mutations are silent until re-registered")
    @JavaUIActor
    func onChange_isOneShot() async {
        let counter = Counter()
        var changes = 0

        withObservationTracking {
            _ = counter.count
        } onChange: {
            Task { @JavaUIActor in changes += 1 }
        }

        counter.count += 1
        await Task.yield()
        counter.count += 1
        await Task.yield()

        #expect(changes == 1)
    }

    /// The fused `appcoreObserveGet*` thunks rely on per-property dep
    /// registration: a composable that only calls `appcoreObserveGetIsLoading`
    /// should not recompose when stories change. Verifies the tracking scope
    /// is property-granular.
    @Test("only read properties register as dependencies")
    @JavaUIActor
    func onlyReadProperties_areDeps() async {
        let counter = Counter()
        var changes = 0

        withObservationTracking {
            _ = counter.count   // reads count — not other
        } onChange: {
            Task { @JavaUIActor in changes += 1 }
        }

        counter.other += 1      // unread — should not fire
        await Task.yield()
        #expect(changes == 0)

        counter.count += 1      // read — fires
        await Task.yield()
        #expect(changes == 1)
    }

    /// Re-registration after onChange lets further mutations be tracked.
    @Test("re-registration after onChange restores tracking")
    @JavaUIActor
    func reRegistration_restoresTracking() async {
        let counter = Counter()
        var changes = 0

        func register() {
            withObservationTracking {
                _ = counter.count
            } onChange: {
                Task { @JavaUIActor in
                    changes += 1
                    register()   // mirrors composable re-registration
                }
            }
        }

        register()
        counter.count += 1; await Task.yield()
        counter.count += 1; await Task.yield()
        counter.count += 1; await Task.yield()

        #expect(changes == 3)
    }
}
#endif
