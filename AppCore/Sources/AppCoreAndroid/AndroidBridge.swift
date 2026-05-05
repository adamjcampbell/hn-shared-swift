import Foundation
import Observation
import AppCore

/// Android-side coordinator that owns an `AppModel` and an `Observations`
/// task; mediates between sync entry points and async observation.
///
/// **Why this is an actor:** see spec §2.5. `AppModel` is a non-`Sendable`
/// reference shared between (a) entry-point invocations from the JVM and
/// (b) the `Observations` task — they must be in the same isolation domain.
/// The actor *is* that isolation domain.
///
/// **Why a singleton:** there is exactly one `AppModel` per process. Holding
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

    private let appModel = AppModel()
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
            // `lastDeliveredState` skips the JSON-encode + JNI hop when
            // an `Observations` emission is byte-identical to the prior
            // one. `Observations` itself doesn't dedup (every `willSet`
            // starts a transaction even if the value didn't change), and
            // Compose's `mutableStateOf<AppState?>` only saves the
            // recompose, not the wire round-trip. Holding a ~10–30 KB
            // copy buys back ~100 µs of JNI per skipped emission.
            //
            // Local to the Task — re-attach cancels and respawns, so a
            // fresh sink gets a fresh comparison automatically.
            var lastDeliveredState: AppState?
            let observations = Observations { self.appModel.state }
            for await state in observations {
                guard state != lastDeliveredState else { continue }
                lastDeliveredState = state
                self.sink?.deliver(snapshotJSON: state.toJSON())
            }
        }
        #endif
    }

    func detach() {
        observationTask?.cancel()
        observationTask = nil
        sink = nil
    }

    /// Forward a decoded `AppEvent` to the model. Runs on the bridge
    /// actor's executor; subsequent `dispatch` calls queue behind it.
    func dispatch(_ event: AppEvent) async {
        await appModel.dispatch(event)
    }
}
