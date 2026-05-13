import Foundation
@testable import AppCore

/// Per-test isolation shell. Each `TestCore` instance is its own
/// `actor` with its own executor; `AppCoreActor` borrows that executor
/// via `unownedExecutor`. Different `TestCore` instances → different
/// executors → state mutations across tests run in parallel.
///
/// `TestCore` is the test-target counterpart to `AppCore`. Same
/// pattern: shell owns `AppState`, hands `AppCoreActor` an
/// `acquireState` closure that uses `self.assumeIsolated` to access
/// the non-`Sendable` `AppState` on this actor's isolation.
///
/// `handler` is `lazy var` so the compiler doesn't require it
/// initialized before `self` can escape — the lazy expression captures
/// `self` after all other stored properties are assigned, so
/// `AppCoreActor(isolation: self, ...)` is safe by the time it runs.
///
/// Tests read state via named Sendable accessors mirroring the
/// AppState properties they need (`feedStories`, `searchQuery`, etc.).
/// `@dynamicMemberLookup` with `KeyPath<AppState, T>` doesn't work
/// because `KeyPath<AppState, T>` isn't `Sendable` (AppState isn't),
/// so the KeyPath can't cross the actor boundary into the subscript.
/// Named accessors don't have this problem — they're regular
/// actor-isolated properties whose Sendable return crosses just fine.
///
/// Tests write state via the `with<T:>(_:)` ad-hoc helper.
public actor TestCore {
    public let state = AppState()
    public nonisolated let commands: AsyncStream<AppCommand>
    private let commandsContinuation: AsyncStream<AppCommand>.Continuation
    private let client: HNClient
    private let clock: any Clock<Duration>

    lazy var handler: AppCoreActor = AppCoreActor(
        isolation: self,
        commands: commands,
        commandsContinuation: commandsContinuation,
        client: client,
        clock: clock
    )

    /// Async init: the trailing `await self.installAcquireState()`
    /// hops to self's executor before `handler.assumeIsolated` checks
    /// executor equality (current == self.unownedExecutor ==
    /// handler.unownedExecutor — borrowed). The Swift 6 compiler may
    /// emit a "no async operations" warning on the await — it doesn't
    /// recognise the implicit-isolation hop as an async operation, but
    /// the hop happens at runtime regardless.
    public init(
        client: HNClient = HNClient(),
        clock: any Clock<Duration> = ContinuousClock()
    ) async {
        let (stream, continuation) = AsyncStream<AppCommand>.makeStream()
        self.commands = stream
        self.commandsContinuation = continuation
        self.client = client
        self.clock = clock
        await self.installAcquireState()
    }

    /// Actor-isolated, **sync** — `assumeIsolated` is unavailable
    /// from async contexts. Calling this via `await` from init hops
    /// to self's executor before the sync body runs, so the
    /// `handler.assumeIsolated` precondition (current executor ==
    /// handler.unownedExecutor == self's executor) holds.
    ///
    /// First access of `handler` here triggers its lazy
    /// initialization with `isolation: self` — by which time all
    /// other stored properties are assigned.
    private func installAcquireState() {
        handler.assumeIsolated { handler in
            handler.acquireState = { [weak self] mutation in
                guard let self else { return }
                self.assumeIsolated { tc in
                    mutation(tc.state)
                }
            }
        }
    }

    // MARK: - Public dispatch surface (mirrors AppCore)

    public func dispatch(_ event: AppEvent) async {
        await handler.dispatch(event)
    }

    public func run() async {
        await handler.run()
    }

    // MARK: - Named Sendable read accessors

    /// Mirror the AppState properties tests actually read. Each is
    /// an actor-isolated property returning a Sendable value, so
    /// `await testCore.foo` reads the underlying `state.foo` with
    /// one actor hop.
    public var searchQuery: String { state.searchQuery }
    public var searchQueryChanges: AsyncStream<String> { state.searchQueryChanges }
    public var feed: LoadableHits { state.feed }
    public var search: LoadableHits { state.search }
    public var feedStories: [Story] { state.feedStories }
    public var searchResults: [Story] { state.searchResults }
    public var readIds: Set<String> { state.readIds }

    // MARK: - Ad-hoc reads/writes

    /// Generic state access for tests that need a one-off read,
    /// write, or compound read+write. Body runs on this actor's
    /// isolation; mutations and Sendable returns work the same way.
    public func with<T: Sendable>(_ work: @Sendable (AppState) -> T) -> T {
        work(state)
    }
}
