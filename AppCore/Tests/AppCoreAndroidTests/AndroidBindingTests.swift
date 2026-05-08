#if canImport(Android)
import Foundation
import Observation
import Testing
@testable import AppCoreAndroid

/// Stand-in `@Observable` root used to exercise `AndroidBinding` in
/// isolation. Mirrors the production shape (`AppState` is also
/// `@Observable final class` with a per-property bridge) without
/// pulling the rest of `AppCore` into the test.
@Observable
private final class MockRoot {
    var query: String = ""
}

/// Reference-typed sink for capturing deliveries from inside the
/// `@JavaUIActor`-isolated binding closure. A local `var` capture
/// would require strict-concurrency gymnastics; a class instance
/// gives us shared mutation through a reference, all serialized
/// through `@JavaUIActor`.
@JavaUIActor
private final class Recorder {
    var deliveries: [String] = []
    func append(_ value: String) { deliveries.append(value) }
}

@Suite("AndroidBinding echo dedup")
struct AndroidBindingTests {
    @Test("set(value) suppresses the matching observation emission")
    @JavaUIActor
    func set_suppressesEcho() async {
        let root = MockRoot()
        let recorder = Recorder()
        let binding = AndroidBinding<MockRoot, String>(
            root: root,
            keyPath: \.query,
            deliver: recorder.append(_:)
        )
        binding.start()
        // Cold-start emission ("") lands first; lastSetterValue is nil
        // so it's delivered (mirrors the production cold-start).
        await Task.yield()
        // Compose-side write: records lastSetterValue, applies write.
        binding.set("hello")
        // Observations sees the write but the dedup suppresses delivery.
        await Task.yield()
        binding.stop()

        #expect(recorder.deliveries == [""])
    }

    @Test("external write delivers — dedup only suppresses the most-recent setter")
    @JavaUIActor
    func externalWrite_delivers() async {
        let root = MockRoot()
        let recorder = Recorder()
        let binding = AndroidBinding<MockRoot, String>(
            root: root,
            keyPath: \.query,
            deliver: recorder.append(_:)
        )
        binding.start()
        await Task.yield()                  // cold-start "" lands

        // Programmatic write that didn't go through `set` — e.g., a
        // hypothetical "clear search" Swift-side action. lastSetterValue
        // is still nil, so the binding delivers.
        root.query = "out-of-band"
        await Task.yield()

        binding.stop()
        #expect(recorder.deliveries == ["", "out-of-band"])
    }
}
#endif
