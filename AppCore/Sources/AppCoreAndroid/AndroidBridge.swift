#if canImport(Android)
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
actor AndroidBridge {
    private let state = AppState()
    private let sink: any SnapshotSink
    private var observationTask: Task<Void, Never>?

    init(sink: any SnapshotSink) {
        self.sink = sink
    }

    /// Begin observing. Called once after construction.
    func start() {
        observationTask = Task { [self] in
            let observations = Observations { self.state.snapshot }
            for await snapshot in observations {
                self.sink.deliver(snapshotJSON: snapshot.toJSON())
            }
        }
    }

    func toggleFavorite(_ id: String) {
        state.toggleFavorite(id)
    }

    func refresh() async {
        await state.refresh()
    }

    func close() {
        observationTask?.cancel()
        observationTask = nil
    }
}
#endif
