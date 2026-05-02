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
            let observations = Observations { Snapshot(from: self.state) }
            for await snapshot in observations {
                let json = Self.encode(snapshot)
                self.sink.deliver(snapshotJSON: json)
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

    /// Encode a freshly-initialised snapshot, without entering the actor.
    ///
    /// `Observations` (SE-0475) only emits *on mutation* — it runs its closure
    /// once to determine dependencies but does not deliver an initial value.
    /// On Apple platforms the consumer typically reads the property
    /// synchronously the first time anyway. On Android the consumer (Kotlin)
    /// can only see snapshots delivered through the JNI callback, so we'd
    /// otherwise show empty state until the first mutation. We bridge the
    /// gap by encoding a snapshot from a throwaway `AppState` and delivering
    /// it synchronously in `appcoreCreate`.
    nonisolated static func encodeInitialSnapshot() -> String {
        encode(Snapshot(from: AppState()))
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
#endif
