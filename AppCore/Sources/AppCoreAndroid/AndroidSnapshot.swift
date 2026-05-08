#if canImport(Android)
import Foundation
import Observation
import AppCore

/// Reusable observation pump for an `Encodable` source. Iterates an
/// `Observations { source() }` sequence, encodes each transaction to
/// JSON via `JNICoder`, dedupes byte-identical emissions, and delivers
/// to a `SnapshotSink`.
///
/// Replaces the inline `observationTask` + `lastJSON` shape from the
/// previous `AndroidBridge` actor. Adding a new snapshot pump for a
/// different `@Observable` root is one `AndroidSnapshot<NewState>(...)`
/// instantiation, not another actor method.
///
/// **Why dedupe at this layer:** `Observations` starts a fresh
/// transaction on every `willSet` regardless of whether the property's
/// value actually changed; Compose's `mutableStateOf<AppState?>` would
/// save the recompose, but we'd still pay ~100 µs of JNI per skipped
/// emission. Holding the prior JSON string buys that back. Local to
/// the Task — `start()` cancels and respawns, so a fresh sink gets a
/// fresh comparison automatically.
///
/// **Encoding lives inside the closure** so `Observations` delivers a
/// Sendable `String` representing a consistent snapshot per
/// transaction (the source itself is typically a non-`Sendable`
/// `@Observable` reference).
@JavaUIActor
public final class AndroidSnapshot<S: Encodable> {
    private let source: @JavaUIActor () -> S
    private let sink: any SnapshotSink
    private var task: Task<Void, Never>?

    public init(source: @escaping @JavaUIActor () -> S, sink: any SnapshotSink) {
        self.source = source
        self.sink = sink
    }

    public func start() {
        task?.cancel()
        let source = self.source
        let sink = self.sink
        task = Task {
            var lastJSON: String?
            for await json in Observations({ JNICoder.encode(source()) }) {
                guard json != lastJSON else { continue }
                lastJSON = json
                sink.deliver(snapshotJSON: json)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
#endif
