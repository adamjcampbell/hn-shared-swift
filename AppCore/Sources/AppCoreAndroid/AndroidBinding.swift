#if canImport(Android)
import Foundation
import Observation

/// Two-way binding between a Swift property and a Compose UI control,
/// the Android equivalent of SwiftUI's `@Binding`. Composes the
/// previously-inline pieces (`handleSetSearchQuery`, `getSearchQuery`,
/// `lastSetterValue`, `searchQueryTask`) into a single reusable type.
///
/// Adding a new per-property bridge (e.g. for a future `Bool` toggle or
/// a `Date` picker) is one `AndroidBinding<T>(...)` instantiation plus
/// the matching JNI thunks — not another set of methods on a singleton
/// actor.
///
/// **Echo dedup at the trust boundary.** Compose's `BridgedSource`
/// owns the in-progress typing buffer locally; when it calls [set],
/// the same value would otherwise round-trip back through [start]'s
/// observation pump and clobber the typing buffer. We record the
/// most-recent setter value and skip the matching observation
/// emission. See AGENT.md "trust boundary dedupe" rule.
///
/// **Generic over `T`, sink callback supplied as a closure.** jextract
/// can't generate Java interfaces from generic Swift protocols, so the
/// concrete sink type (e.g. `SearchQuerySink`) stays a regular
/// per-`T` protocol; the binding accepts the deliver-side as a
/// `@JavaUIActor (T) -> Void` closure that wraps it. Keeps this file
/// agnostic to which sink protocol is wired through.
@JavaUIActor
public final class AndroidBinding<T: Equatable & Sendable> {
    /// Sync getter, also the observation source. `Observations`
    /// requires a `@Sendable` closure; `@JavaUIActor`-isolated closures
    /// are implicitly `@Sendable` (SE-0316), so this works without an
    /// explicit annotation.
    private let read: @JavaUIActor () -> T
    /// Sync setter from the JNI thunk. Mutates the underlying property
    /// inline; the matching observation emission is suppressed by the
    /// `lastSetterValue` dedup below.
    private let write: @JavaUIActor (T) -> Void
    /// Delivery callback, typically wrapping a per-`T` jextract'd sink
    /// (e.g. `searchQuerySink.deliverSearchQuery(value:)`).
    private let deliver: @JavaUIActor (T) -> Void
    private var observationTask: Task<Void, Never>?
    private var lastSetterValue: T?

    public init(
        read: @escaping @JavaUIActor () -> T,
        write: @escaping @JavaUIActor (T) -> Void,
        deliver: @escaping @JavaUIActor (T) -> Void
    ) {
        self.read = read
        self.write = write
        self.deliver = deliver
    }

    /// Compose-side write. Records the value for echo dedup, then
    /// applies the platform write.
    public func set(_ value: T) {
        lastSetterValue = value
        write(value)
    }

    /// Sync read. Used by JNI getter thunks (`appcoreGetSearchQuery`
    /// etc.) so Compose's `produceState(initialValue:)` can seed from
    /// Swift's current truth without a Kotlin-side mirror.
    public func get() -> T {
        read()
    }

    /// Spin up the observation pump. `Observations` emits the initial
    /// value plus every subsequent transaction; `lastSetterValue`
    /// suppresses the echo of writes Compose just sent.
    public func start() {
        observationTask?.cancel()
        let read = self.read
        let deliver = self.deliver
        observationTask = Task { [self] in
            for await value in Observations(read) {
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
