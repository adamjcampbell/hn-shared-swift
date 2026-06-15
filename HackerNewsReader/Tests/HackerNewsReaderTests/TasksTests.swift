import Foundation
import Testing
@testable import HackerNewsReader

/// A minimal slot holder, standing in for ``Tasks`` so the policy is
/// exercised in isolation over a plain `Int` rather than a `Page`.
/// `latest`/`cancel` are generic over the slot's class and value.
private final class Box { var slot: Task<Int, Error>? }

/// `@MainActor` so the `Task` literals here inherit the suite's actor and
/// share the non-`Sendable` ``Box``, mirroring how production confines a
/// ``Tasks`` registry on `MainActor`.
@Suite("latest / cancel")
@MainActor
struct TasksTests {

    @Test("runs the work and returns its value")
    func returnsValue() async throws {
        let box = Box()
        #expect(try await latest(\Box.slot, on: box) { 42 } == 42)
    }

    @Test("a second call cancels the in-flight one; the superseded caller throws CancellationError")
    func newCallSupersedes() async throws {
        let box = Box()
        let gate = Gate()

        let first = Task {
            try await latest(\Box.slot, on: box) {
                await gate.arrive()
                try Task.checkCancellation()
                return 1
            }
        }
        // `first`'s work is parked in the slot before the second call lands.
        await gate.arrival()

        let second = try await latest(\Box.slot, on: box) { 2 }
        #expect(second == 2)
        await #expect(throws: CancellationError.self) { _ = try await first.value }
    }

    @Test("cancel(_:on:) cancels the in-flight work and empties the slot")
    func cancelStopsInFlight() async throws {
        let box = Box()
        let gate = Gate()

        let task = Task {
            try await latest(\Box.slot, on: box) {
                await gate.arrive()
                try Task.checkCancellation()
                return 1
            }
        }
        await gate.arrival()

        cancel(\Box.slot, on: box)
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(box.slot == nil)
    }

    @Test("errors thrown by the work propagate to the caller")
    func propagatesErrors() async {
        struct Boom: Error {}
        let box = Box()
        await #expect(throws: Boom.self) { _ = try await latest(\Box.slot, on: box) { throw Boom() } }
    }

    @Test("a URLError(.cancelled) from the work is normalised to CancellationError")
    func urlCancelledNormalised() async {
        let box = Box()
        await #expect(throws: CancellationError.self) {
            _ = try await latest(\Box.slot, on: box) { throw URLError(.cancelled) }
        }
    }

    @Test("a superseded caller throws even when its work ignores cancellation and returns a value")
    func supersededCallerThrowsDespiteCompletedWork() async throws {
        let box = Box()
        let hold = Hold()

        let first = Task {
            try await latest(\Box.slot, on: box) {
                await hold.wait()   // ignores the supersede cancel
                return 1            // returns a value despite having been cancelled
            }
        }
        await hold.arrival()        // first's work is parked in the slot

        let second = try await latest(\Box.slot, on: box) { 2 }   // supersedes
        #expect(second == 2)

        hold.release()              // first's work now completes, delivering 1 to a cancelled task
        // Cancel-and-replace is latest-wins: the superseded caller must observe
        // cancellation, not the stale value its work happened to return.
        await #expect(throws: CancellationError.self) { _ = try await first.value }
    }
}
