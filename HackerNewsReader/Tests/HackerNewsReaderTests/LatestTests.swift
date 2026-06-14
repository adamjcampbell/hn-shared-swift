import Foundation
import Testing
@testable import HackerNewsReader

/// `@MainActor` so the `Task` literals here inherit the suite's actor and
/// share the non-`Sendable` ``Latest`` instance, mirroring how production
/// confines it on `MainActor`.
@Suite("Latest")
@MainActor
struct LatestTests {

    @Test("runs the work and returns its value")
    func returnsValue() async throws {
        let latest = Latest<Int>()
        #expect(try await latest { 42 } == 42)
    }

    @Test("a second call cancels the in-flight one; the superseded caller throws CancellationError")
    func newCallSupersedes() async throws {
        let latest = Latest<Int>()
        let gate = Gate()

        let first = Task {
            try await latest {
                await gate.arrive()
                try Task.checkCancellation()
                return 1
            }
        }
        // `first`'s work is parked inside the slot before the second call lands.
        await gate.arrival()

        let second = try await latest { 2 }
        #expect(second == 2)
        await #expect(throws: CancellationError.self) { _ = try await first.value }
    }

    @Test("cancel() cancels the in-flight work")
    func cancelStopsInFlight() async throws {
        let latest = Latest<Int>()
        let gate = Gate()

        let task = Task {
            try await latest {
                await gate.arrive()
                try Task.checkCancellation()
                return 1
            }
        }
        await gate.arrival()

        latest.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("errors thrown by the work propagate to the caller")
    func propagatesErrors() async {
        struct Boom: Error {}
        let latest = Latest<Int>()
        await #expect(throws: Boom.self) { _ = try await latest { throw Boom() } }
    }

    @Test("a superseded caller throws even when its work ignores cancellation and returns a value")
    func supersededCallerThrowsDespiteCompletedWork() async throws {
        let latest = Latest<Int>()
        let hold = Hold()

        let first = Task {
            try await latest {
                await hold.wait()   // ignores the supersede cancel
                return 1            // returns a value despite having been cancelled
            }
        }
        await hold.arrival()        // first's work is parked inside the slot

        let second = try await latest { 2 }   // supersedes: cancels first's inner task
        #expect(second == 2)

        hold.release()              // first's work now completes, delivering 1 to a cancelled task
        // Cancel-and-replace is latest-wins: the superseded caller must observe
        // cancellation, not the stale value its work happened to return.
        await #expect(throws: CancellationError.self) { _ = try await first.value }
    }
}
