/// Synchronous receiver for the cancellation token of an observation
/// Task. Fired inline by `appcoreObserve*` *before* the thunk returns,
/// so Kotlin learns the token in the same construction step that
/// delivers the initial value.
///
/// jextract emits a Java interface; Kotlin SAM-converts lambdas:
/// `Subscription { token -> ... }`.
///
/// The pair `(OnChange, Subscription)` lets a single observe thunk fuse
/// what would otherwise need two: an `appcoreObserve*` returning the
/// initial value and a separate `appcoreRegisterObservation` returning
/// the token. With the subscription callback Kotlin gets the token
/// synchronously inside one round-trip.
public protocol Subscription: Sendable {
    func attached(token: Int64)
}
