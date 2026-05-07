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
    private var searchQuerySink: (any SearchQuerySink)?
    private var observationTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var searchQueryTask: Task<Void, Never>?
    private var queryWatcherTask: Task<Void, Never>?

    /// Most-recent value passed in via `handleSetSearchQuery`. Used to
    /// suppress the inevitable echo when Compose types into the field —
    /// without this, every keystroke would round-trip back through the
    /// sink and clobber Compose's local mirror mid-typing. See AGENT.md
    /// "trust boundary dedupe" rule.
    private var lastSetterValue: String?

    private init() {}

    /// Attach all three sinks and (re)start the observation, command,
    /// search-query, and watcher pumps. Idempotent: a second call cancels
    /// the prior tasks and replaces the sinks, which is what tests need
    /// to do between cases without a dedicated reset hook.
    func attach(
        snapshotSink: any SnapshotSink,
        commandSink: any CommandSink,
        searchQuerySink: any SearchQuerySink
    ) {
        observationTask?.cancel()
        commandTask?.cancel()
        searchQueryTask?.cancel()
        queryWatcherTask?.cancel()
        self.snapshotSink = snapshotSink
        self.commandSink = commandSink
        self.searchQuerySink = searchQuerySink
        lastSetterValue = nil
        #if canImport(Android)
        observationTask = Task { [self] in
            // `lastJSON` coalesces emissions that encode to a
            // byte-identical snapshot. `Observations` already coalesces
            // synchronous `willSet`s within a transaction, but starts a
            // fresh transaction on every `willSet` regardless of whether
            // the property's value actually changed; Compose's
            // `mutableStateOf<AppState?>` saves the recompose, not the
            // JNI round-trip. Holding the prior JSON string buys back
            // ~100 µs of JNI per skipped emission.
            //
            // Encoding lives inside the closure so `Observations`
            // delivers a Sendable `String` representing a consistent
            // snapshot per transaction (the `@Observable` `AppState`
            // is itself a non-`Sendable` reference). `toJSON()` reads
            // every encoded property *except* `searchQuery`, which is
            // bridged separately via `searchQueryTask`.
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
        searchQueryTask = Task { [self] in
            // Per-property push: emits the initial value of
            // `state.searchQuery` on attach (per `Observations`'
            // initial-value semantics, the same way the snapshot loop
            // emits its cold-start value), then on every willSet. The
            // `lastSetterValue` dedup suppresses echoes of writes
            // Compose just sent — Compose already has the value locally
            // and re-applying it would race with in-progress typing.
            for await query in Observations({ self.appModel.state.searchQuery }) {
                if query == self.lastSetterValue { continue }
                self.searchQuerySink?.deliverSearchQuery(value: query)
            }
        }
        queryWatcherTask = Task { [self] in
            // searchQuery watcher lives on AppModel —
            // `runSearchQueryWatcher` iterates
            // `state.observe(\.searchQuery)` and drives `runFetch` on
            // each willSet. Wrapped here in `runSearchQueryWatcher` (an
            // actor-method that re-enters the bridge actor before
            // touching `appModel`) so the non-Sendable AppModel
            // reference never leaves the actor's region. The Task
            // captures only `self` (the actor, Sendable).
            await self.runSearchQueryWatcher()
        }
        #endif
    }

    func detach() {
        observationTask?.cancel()
        observationTask = nil
        commandTask?.cancel()
        commandTask = nil
        searchQueryTask?.cancel()
        searchQueryTask = nil
        queryWatcherTask?.cancel()
        queryWatcherTask = nil
        snapshotSink = nil
        commandSink = nil
        searchQuerySink = nil
        lastSetterValue = nil
    }

    /// Forward a decoded `AppEvent` to the model. Runs on the bridge
    /// actor's executor; subsequent `dispatch` calls queue behind it.
    func dispatch(_ event: AppEvent) async {
        await appModel.dispatch(event)
    }

    /// Per-property setter for `state.searchQuery`. Records the value
    /// in `lastSetterValue` so the matching emission from
    /// `searchQueryTask` is suppressed (echo dedup), then writes the
    /// property — `queryWatcherTask` sees the willSet and fires the
    /// debounced fetch.
    func handleSetSearchQuery(_ value: String) {
        lastSetterValue = value
        appModel.state.searchQuery = value
    }

    // MARK: - Watcher actor-hop wrapper
    //
    // The `queryWatcherTask`'s body captures only `self` (the actor,
    // Sendable). When it `await self.runSearchQueryWatcher()`, we
    // re-enter the actor's executor and forward to `appModel`'s
    // watcher — the non-Sendable AppModel reference never has to
    // exit the actor's region.

    func runSearchQueryWatcher() async {
        await appModel.runSearchQueryWatcher()
    }
}
