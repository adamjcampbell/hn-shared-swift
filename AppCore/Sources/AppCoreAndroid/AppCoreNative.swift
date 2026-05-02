#if canImport(Android)
import Foundation
import AppCore

// MARK: - Handle table
//
// Each `appcoreCreate` returns an Int64 handle that the Kotlin caller must
// pass back to subsequent `toggle/refresh/destroy` calls. We keep the
// `AndroidBridge` instances alive in a process-global table.

private final class HandleTable: @unchecked Sendable {
    private var nextID: Int64 = 1
    private var bridges: [Int64: AndroidBridge] = [:]
    private let lock = NSLock()

    func insert(_ bridge: AndroidBridge) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID &+= 1
        bridges[id] = bridge
        return id
    }

    func get(_ id: Int64) -> AndroidBridge? {
        lock.lock(); defer { lock.unlock() }
        return bridges[id]
    }

    func remove(_ id: Int64) -> AndroidBridge? {
        lock.lock(); defer { lock.unlock() }
        return bridges.removeValue(forKey: id)
    }
}

private let handles = HandleTable()

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

public func appcoreCreate(sink: some SnapshotSink) -> Int64 {
    let bridge = AndroidBridge(sink: sink)
    let id = handles.insert(bridge)
    // Observations (SE-0475) only emits on mutation — see AndroidBridge.
    // Deliver the initial snapshot synchronously so the Compose UI has
    // something to render before the user does anything.
    sink.deliver(snapshotJSON: AndroidBridge.encodeInitialSnapshot())
    Task { await bridge.start() }
    return id
}

public func appcoreToggleFavorite(handle: Int64, id: String) {
    guard let bridge = handles.get(handle) else { return }
    Task { await bridge.toggleFavorite(id) }
}

public func appcoreRefresh(handle: Int64) {
    guard let bridge = handles.get(handle) else { return }
    Task { await bridge.refresh() }
}

public func appcoreDestroy(handle: Int64) {
    guard let bridge = handles.remove(handle) else { return }
    Task { await bridge.close() }
}
#endif
