import Foundation
import Observation
import AppCore

/// The Android-side coordinator. Owns an `AppState` and an `Observations`
/// task; mediates between sync JNI entry points and async observation.
///
/// **Why this is an actor:** see spec §2.5. In short — `AppState` is a
/// non-`Sendable` reference shared between (a) JNI mutation entry points
/// running on JVM threads and (b) the `Observations` task. They must be
/// in the same isolation domain. The actor *is* that isolation domain.
///
/// **Why methods forward to `state`:** the methods on `AppState` are sync
/// and non-isolated; calling them from the actor automatically runs them
/// on the actor's executor (because the actor holds the only reference to
/// the state). This isn't double-handling — it's how the actor's isolation
/// reaches the methods.
public actor AndroidBridge {
    private let state = AppState()
    private let sink: any SnapshotSink
    private var observationTask: Task<Void, Never>?

    public init(sink: any SnapshotSink) {
        self.sink = sink
    }

    /// Begin observing. The caller (the JNI `create` entry point) calls
    /// this once after construction.
    public func start() {
        // The Task body inherits this actor's isolation (Task.init is
        // marked @_inheritActorContext when the surrounding context is
        // actor-isolated — see SE-0420 / SE-0431).
        //
        // The Observations closure also picks up this actor as its
        // isolation via the #isolation default parameter on
        // Observations.init (SE-0475). So `state.cities` etc. are read
        // synchronously on the actor's executor — no data race.
        observationTask = Task { [self] in
            let observations = Observations { Snapshot(from: self.state) }
            for await snapshot in observations {
                let json = Self.encode(snapshot)
                self.sink.deliver(snapshotJSON: json)
            }
        }
    }

    public func toggleFavorite(_ id: String) {
        state.toggleFavorite(id)
    }

    public func refresh() async {
        await state.refresh()
    }

    public func close() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Encoding

    private static func encode(_ snapshot: Snapshot) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
