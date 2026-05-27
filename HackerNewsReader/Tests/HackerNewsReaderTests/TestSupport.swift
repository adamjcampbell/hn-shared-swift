import Clocks
import DebugSnapshots
import Foundation
import Testing
@testable import HackerNewsReader
import HackerNews

extension ChangeLogger {
    /// Snapshots `Model` before/after each unit of work and logs the
    /// diff via DebugSnapshots (`os.Logger` subsystem `DebugSnapshots` on
    /// Apple, `print` elsewhere). `quiet: true` suppresses no-change work.
    static let logging = ChangeLogger { model in
        let before = snap(model)
        return { label in _logChanges(before, snap(model), label, quiet: true) }
    }
}

/// Fixed reference time. Pins `Dependencies.date` (via `withEngine(now:)`)
/// so `StoryRow.metaLine` is deterministic — required when a snapshot
/// captures the `feedStories` / `searchResults` projections.
let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

let storyA = Story(
    id: "100", title: "Top story", author: "alice",
    score: 50, commentCount: 10,
    url: "https://example.com/a",
    createdAt: Date(timeIntervalSince1970: 1)
)
let storyB = Story(
    id: "101", title: "Second story", author: "bob",
    score: 20, commentCount: 3,
    url: nil,
    createdAt: Date(timeIntervalSince1970: 2)
)
let storyC = Story(
    id: "102", title: "Page-1 story", author: "carol",
    score: 9, commentCount: 1,
    url: "https://example.com/c",
    createdAt: Date(timeIntervalSince1970: 3)
)

/// Convenience: a single-page response.
func page(_ stories: [Story], totalPages: Int = 1) -> Page {
    Page(stories: stories, totalPages: totalPages)
}

extension Engine {
    /// Tests construct `Engine` with `TestActor` isolation and (by
    /// default) an `ImmediateClock`; these accessors reach the
    /// test-specific instance without threading it as a separate local.
    /// `#require` makes a misuse (production isolation in a test, or a
    /// non-`TestClock` where one is needed) surface as a graceful test
    /// failure, not a trap.
    nonisolated var testActor: TestActor {
        get throws { try #require(isolation as? TestActor) }
    }
    nonisolated var testClock: TestClock<Duration> {
        get throws { try #require(clock as? TestClock<Duration>) }
    }

    /// Batches multiple reads and `sendMessage(_:)` calls into one
    /// isolation hop with a consistent snapshot — no other Task can
    /// interleave between statements inside the block.
    ///
    /// - Parameter body: Closure that runs while isolated to the
    ///   actor; receives `self` as its only argument.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Whatever `body` throws.
    func run<R, Failure: Error>(
        _ body: sending @Sendable (isolated Engine) async throws(Failure) -> R
    ) async throws(Failure) -> R {
        try await body(self)
    }
}

/// Per-test ``Engine`` fixture. Builds the actor (with its
/// `TestActor` isolation, the supplied `Client` / clock / now), runs
/// `body`, and awaits `engine.cancelAll()` on exit so the listener
/// Task is cancelled deterministically before the next test starts.
///
/// Default clock is `ImmediateClock`: the only `clock.sleep` in
/// production is the search debounce, and tests that don't validate
/// timing run faster (and need fewer `runPending` calls) with that
/// sleep elided. Override with `clock: TestClock()` when the test
/// asserts on debounce timing.
///
/// - Note: The body's outcome is captured as a `Result` so the
///   teardown runs on a single path before rethrowing via `.get()`;
///   `defer` can't `await`. The stdlib's async
///   `Result.init(catching:)` requires a `@concurrent` closure, but
///   this body captures task-isolated state, so the catch is manual.
func withEngine<R>(
    model: sending Model = Model(),
    client: Client = .mock(),
    clock: any Clock<Duration> = ImmediateClock(),
    now: @escaping @Sendable () -> Date = Date.init,
    body: (Engine) async throws -> R
) async throws -> R {
    // Engine construction is outside `withValue` so the non-`Sendable`
    // `model` parameter consumes without crossing the closure's
    // concurrent region. `bind()` and `body` run inside the binding so
    // the listener `Task` spawned by `bind()` inherits the pinned `now`.
    let engine = Engine(model: model, client: client, clock: clock, isolation: TestActor())
    let result: Result<R, Error>
    do {
        result = .success(try await Dependencies.$date.withValue(DateGenerator(now)) {
            // Logging on by default for tests; the injected logger diffs each message and search commit.
            try await Dependencies.$changeLogger.withValue(.logging) {
                await engine.bind()
                return try await body(engine)
            }
        })
    } catch { result = .failure(error) }
    await engine.cancelAll()
    return try result.get()
}
