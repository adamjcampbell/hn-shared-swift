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
    private var snapshotSink: (any SnapshotSink)?
    private var commandSink: (any CommandSink)?
    private var observationTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?

    private init() {}

    /// Attach both sinks and (re)start the observation + command pumps.
    /// Idempotent: a second call cancels the prior tasks and replaces
    /// the sinks, which is what tests need to do between cases without
    /// a dedicated reset hook.
    func attach(snapshotSink: any SnapshotSink, commandSink: any CommandSink) {
        observationTask?.cancel()
        commandTask?.cancel()
        self.snapshotSink = snapshotSink
        self.commandSink = commandSink
        #if canImport(Android)
        observationTask = Task { [self] in
            // `lastJSON` skips the JNI hop when an `Observations`
            // emission encodes to byte-identical JSON. `Observations`
            // itself doesn't dedup (every `willSet` starts a transaction
            // even if the value didn't change), and Compose's
            // `mutableStateOf<AppState?>` only saves the recompose, not
            // the wire round-trip. Holding the prior JSON string buys
            // back ~100 µs of JNI per skipped emission.
            //
            // Encoding lives inside the closure so `Observations`
            // captures a Sendable `String` per transaction (the
            // `@Observable` `AppState` is a non-`Sendable` reference).
            // `toJSON()` reads every wire-visible property, which is
            // exactly the dependency set we want tracked.
            //
            // Local to the Task — re-attach cancels and respawns, so a
            // fresh sink gets a fresh comparison automatically.
            var lastJSON: String?
            let observations = Observations { self.appModel.state.toJSON() }
            for await json in observations {
                guard json != lastJSON else { continue }
                lastJSON = json
                self.snapshotSink?.deliver(snapshotJSON: json)
            }
        }
        commandTask = Task { [self] in
            // One consumer per platform binary, so the single-iterator
            // constraint of `AsyncStream` is respected. The model's
            // continuation outlives the task; cancelling here leaves
            // the stream open for a re-attach.
            for await command in self.appModel.commands {
                self.commandSink?.deliverCommand(commandJSON: command.toJSON())
            }
        }
        #endif
    }

    func detach() {
        observationTask?.cancel()
        observationTask = nil
        commandTask?.cancel()
        commandTask = nil
        snapshotSink = nil
        commandSink = nil
    }

    /// Forward a decoded `AppEvent` to the model. Runs on the bridge
    /// actor's executor; subsequent `dispatch` calls queue behind it.
    func dispatch(_ event: AppEvent) async {
        await appModel.dispatch(event)
    }
}
