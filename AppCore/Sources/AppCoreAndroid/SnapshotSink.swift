import Foundation

/// The Swift-side protocol implemented by the JNI callback bridge.
///
/// Exists so `AndroidBridge` doesn't import any JNI symbols directly —
/// the JNI implementation conforms to this and is injected at construction.
public protocol SnapshotSink: AnyObject, Sendable {
    func deliver(snapshotJSON: String)
}
