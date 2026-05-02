import Foundation
import Observation
import AppCore

/// Android-side coordinator that owns an `AppState` and an `Observations`
/// task; mediates between sync entry points and async observation.
///
/// **Why this is an actor:** see spec §2.5. `AppState` is a non-`Sendable`
/// reference shared between (a) entry-point invocations from the JVM and
/// (b) the `Observations` task — they must be in the same isolation domain.
/// The actor *is* that isolation domain.
///
/// **Why a singleton:** there is exactly one `AppState` per process. Holding
/// the bridge as `static let shared` means we don't need a hand-rolled
/// `@unchecked Sendable` handle table to keep instances alive across JNI
/// calls — the actor reference is the handle, and actors are inherently
/// `Sendable`.
///
/// The `Observations` machinery is only available on the Android-target
/// build (and on Apple toolchains newer than this package's macOS
/// deployment target), so the body of `attach(sink:)` is gated on
/// `canImport(Android)`. On macOS the bridge compiles as a no-op so that
/// jextract can still see the public entry points in `AppCoreNative.swift`.
actor AndroidBridge {
    static let shared = AndroidBridge()

    private let state = AppState()
    private var sink: (any SnapshotSink)?
    private var observationTask: Task<Void, Never>?

    private init() {}

    /// Attach a snapshot sink and (re)start the observation loop. Idempotent:
    /// a second call cancels the prior observation task and replaces the
    /// sink, which is what tests need to do between cases without a
    /// dedicated reset hook.
    func attach(sink: any SnapshotSink) {
        observationTask?.cancel()
        self.sink = sink
        #if canImport(Android)
        observationTask = Task { [self] in
            let observations = Observations { self.state.snapshot }
            for await snapshot in observations {
                self.sink?.deliver(snapshotJSON: snapshot.toJSON())
            }
        }
        #endif
    }

    func detach() {
        observationTask?.cancel()
        observationTask = nil
        sink = nil
    }

    func toggleFavorite(_ id: String) {
        state.toggleFavorite(id)
    }

    func refresh() async {
        await state.refresh()
    }
}
