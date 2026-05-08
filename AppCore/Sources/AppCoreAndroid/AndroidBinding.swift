#if canImport(Android)
import Foundation
import Observation

/// Two-way binding between a property on an `@Observable` reference and
/// a Compose UI control — the Android equivalent of SwiftUI's `@Binding`.
/// Composes `set` (Compose-side write), `get` (cold-start read), echo
/// dedup (`lastSetterValue`), and an observation pump that pushes
/// out-of-band Swift writes back through the per-`Value` sink callback.
///
/// **`(root, keyPath)` instead of read/write closures.** A
/// `ReferenceWritableKeyPath` proves at the type level that the read
/// and write sides reach the same property — earlier shapes used two
/// separate closures and trusted convention.
///
/// **Echo dedup at the trust boundary.** Compose's `BridgedSource`
/// owns the in-progress typing buffer locally; when it calls [set],
/// the same value would otherwise round-trip back through [start]'s
/// observation pump and clobber the typing buffer. We record the
/// most-recent setter value and skip the matching observation
/// emission. See AGENT.md "trust boundary dedupe" rule.
///
/// **Sink callback supplied as a closure.** jextract can't generate
/// Java interfaces from generic Swift protocols, so the concrete sink
/// type (e.g. `SearchQuerySink`) stays a regular per-`Value` protocol
/// and the binding accepts the deliver-side as a `@JavaUIActor (Value) -> Void`
/// closure that wraps it. Keeps this file agnostic to which sink
/// protocol is wired through.
@JavaUIActor
public final class AndroidBinding<Root: AnyObject & Observable, Value: Equatable & Sendable> {
    private let root: Root
    private let keyPath: ReferenceWritableKeyPath<Root, Value>
    private let deliver: @JavaUIActor (Value) -> Void
    private var observationTask: Task<Void, Never>?
    private var lastSetterValue: Value?

    public init(
        root: Root,
        keyPath: ReferenceWritableKeyPath<Root, Value>,
        deliver: @escaping @JavaUIActor (Value) -> Void
    ) {
        self.root = root
        self.keyPath = keyPath
        self.deliver = deliver
    }

    /// Compose-side write. Records the value for echo dedup, then
    /// applies the platform write.
    public func set(_ value: Value) {
        lastSetterValue = value
        root[keyPath: keyPath] = value
    }

    /// Sync read. Used by JNI getter thunks (`appcoreGetSearchQuery`
    /// etc.) so Compose's `produceState(initialValue:)` can seed from
    /// Swift's current truth without a Kotlin-side mirror.
    public func get() -> Value {
        root[keyPath: keyPath]
    }

    /// Spin up the observation pump. `Observations` emits the initial
    /// value plus every subsequent transaction; `lastSetterValue`
    /// suppresses the echo of writes Compose just sent.
    ///
    /// Uses stdlib `Observations` directly rather than the
    /// `ObservedKeyPath`/`Observable.observe(_:)` shim in
    /// `AppCore/Sources/AppCore/Observed.swift` — that shim exists
    /// because cross-platform `AppCore` deploys to iOS 17 (where
    /// `Observations` isn't available), but the Android cross-build's
    /// Swift toolchain has `Observations` natively.
    public func start() {
        observationTask?.cancel()
        observationTask = Task { [self, root, keyPath] in
            for await value in Observations({ root[keyPath: keyPath] }) {
                if value == lastSetterValue { continue }
                deliver(value)
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }
}
#endif
