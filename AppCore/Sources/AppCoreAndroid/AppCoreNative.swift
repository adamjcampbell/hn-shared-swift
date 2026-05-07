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
// none of these entry points take a handle. Command-shaped mutations are
// funnelled through `appcoreDispatch(eventJSON:)` that decodes a Codable
// `AppEvent`. Continuously-bound primitives (currently `searchQuery`) get
// dedicated per-property setters and matching push sinks; adding a new
// mutation case in `AppCore` covers both shapes.

public func appcoreCreate(
    snapshotSink: some SnapshotSink,
    commandSink: some CommandSink,
    searchQuerySink: some SearchQuerySink
) {
    // `Observations` (Swift 6.2+) emits an initial value as well as all
    // future ones (see WWDC25 *What's new in Swift*), so the bridge
    // actor's `attach()` already delivers a cold-start snapshot ~1–2 ms
    // after this call returns. `BridgePerfTest.a_coldStart_…` is the
    // regression guard. Compose reads `AppModelHolder.state` as a
    // nullable `AppState?`, so the brief window before that emission
    // lands renders the same empty-state UI as the initial snapshot
    // would have. The `searchQuerySink` similarly emits the cold-start
    // value of `state.searchQuery` (initially `""`) within the same
    // window.
    Task {
        await AndroidBridge.shared.attach(
            snapshotSink: snapshotSink,
            commandSink: commandSink,
            searchQuerySink: searchQuerySink
        )
    }
}

public func appcoreDispatch(eventJSON: String) {
    guard let event = AppEvent(json: eventJSON) else {
        print("appcoreDispatch: failed to decode AppEvent from \(eventJSON)")
        return
    }
    Task { await AndroidBridge.shared.dispatch(event) }
}

/// Per-property setter for `state.searchQuery`. Compose calls this on
/// every keystroke. The bridge dedups echoes via `lastSetterValue` so
/// the value Compose just typed isn't pushed back through `SearchQuerySink`
/// to clobber the in-progress text.
public func appcoreSetSearchQuery(value: String) {
    Task { await AndroidBridge.shared.handleSetSearchQuery(value) }
}

public func appcoreDestroy() {
    Task { await AndroidBridge.shared.detach() }
}
