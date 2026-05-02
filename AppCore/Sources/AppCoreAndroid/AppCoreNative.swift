import Foundation
import AppCore

// MARK: - jextract entry points
//
// These public functions are scanned by `swift-java jextract --mode=jni`
// (configured via `swift-java.config` in this directory; the
// `JExtractSwiftPlugin` SwiftPM plugin runs it as part of `swift build`).
// jextract generates a Java class `com.example.appcore.bridge.AppCoreAndroid`
// — named after the Swift module — with matching `native` static methods,
// plus a Swift `@_cdecl` glue file. We never write the JNI naming or
// marshalling by hand. Note: `native` is a Java reserved keyword, so the
// Java package is `…bridge` rather than `…native`.
//
// There is one `AppModel` per process, owned by `AndroidBridge.shared`, so
// none of these entry points take a handle. Mutations are funnelled
// through a single `appcoreDispatch(eventJSON:)` that decodes a Codable
// `AppEvent` — adding a new mutation case in `AppCore` is the only thing
// required to expose a new action to Kotlin.

public func appcoreCreate(sink: some SnapshotSink) {
    // Observations (SE-0475) only emits on mutation, so deliver an initial
    // snapshot synchronously before the actor task is scheduled. This is
    // the load-bearing path for `BridgePerfTest.a_coldStart_…`.
    sink.deliver(snapshotJSON: AppState().toJSON())
    Task { await AndroidBridge.shared.attach(sink: sink) }
}

public func appcoreDispatch(eventJSON: String) {
    guard let event = AppEvent(json: eventJSON) else {
        print("appcoreDispatch: failed to decode AppEvent from \(eventJSON)")
        return
    }
    Task { await AndroidBridge.shared.dispatch(event) }
}

public func appcoreDestroy() {
    Task { await AndroidBridge.shared.detach() }
}
