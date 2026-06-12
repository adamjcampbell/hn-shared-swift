import Clocks
import Foundation
import Testing
@testable import HackerNewsReader

/// `@MainActor` so `#isolation` in ``makeRegistry(isolation:)`` binds the
/// suite to one actor — the registry, its spawned tasks, and the test
/// body share that region, mirroring how `makeCore` confines production.
@Suite("TaskRegistry")
@MainActor
struct TaskRegistryTests {

    private enum ID: Hashable { case a, b }

    /// Parks until cancelled: the clock is never advanced, and
    /// cancellation throws the sleep out.
    private let clock = TestClock<Duration>()

    private func parked() -> () async -> Void {
        { [clock] in try? await clock.sleep(for: .seconds(Int.max)) }
    }

    @Test("run cancels and replaces the in-flight task for the same id")
    func runCancelsAndReplaces() async {
        let registry = makeRegistry()
        let first = registry.run(.a, work: parked())

        let second = registry.run(.a, work: parked())
        defer { registry.cancelAll() }

        #expect(first.isCancelled)
        #expect(!second.isCancelled)
    }

    @Test("joinInFlight returns the in-flight task and drops the new work")
    func joinInFlightReturnsExisting() async {
        let registry = makeRegistry()
        var joinedWorkRan = false
        let first = registry.run(.a, work: parked())

        let joined = registry.run(.a, strategy: .joinInFlight) { joinedWorkRan = true }

        #expect(joined == first)
        #expect(!first.isCancelled)

        registry.cancel(.a)
        await first.value
        #expect(!joinedWorkRan)
    }

    @Test("a finished task vacates its slot, so joinInFlight starts fresh work")
    func joinInFlightAfterCompletionStartsFresh() async {
        let registry = makeRegistry()
        let first = registry.run(.a) {}
        await first.value

        var freshWorkRan = false
        let second = registry.run(.a, strategy: .joinInFlight) { freshWorkRan = true }

        #expect(second != first)
        await second.value
        #expect(freshWorkRan)
    }

    @Test("a replaced task finishing late does not vacate the replacement's slot")
    func staleCompletionDoesNotClobberReplacement() async {
        let registry = makeRegistry()
        let first = registry.run(.a, work: parked())
        let second = registry.run(.a, work: parked())
        defer { registry.cancelAll() }

        // The cancelled first task unparks and runs its self-removal
        // guard against a slot that now belongs to the second task.
        await first.value

        let joined = registry.run(.a, strategy: .joinInFlight) {}
        #expect(joined == second)
    }

    @Test("cancel cancels and removes the entry")
    func cancelCancelsAndRemoves() async {
        let registry = makeRegistry()
        let task = registry.run(.a, work: parked())

        registry.cancel(.a)
        await task.value

        #expect(task.isCancelled)

        // The slot is free again: joinInFlight starts fresh work.
        var freshWorkRan = false
        await registry.run(.a, strategy: .joinInFlight) { freshWorkRan = true }.value
        #expect(freshWorkRan)
    }

    @Test("tasks for independent ids do not interfere")
    func independentIDsDontInterfere() async {
        let registry = makeRegistry()
        let taskA = registry.run(.a, work: parked())
        let taskB = registry.run(.b, work: parked())
        defer { registry.cancelAll() }

        let replacementA = registry.run(.a, work: parked())

        #expect(taskA.isCancelled)
        #expect(!taskB.isCancelled)
        #expect(!replacementA.isCancelled)
    }

    @Test("cancelAll cancels every in-flight task")
    func cancelAllCancelsEverything() async {
        let registry = makeRegistry()
        let taskA = registry.run(.a, work: parked())
        let taskB = registry.run(.b, work: parked())

        registry.cancelAll()

        #expect(taskA.isCancelled)
        #expect(taskB.isCancelled)
    }

    /// Builds a registry whose spawn mirrors `makeCore`'s: the `Task`
    /// references the isolated parameter so the work runs on the host
    /// actor — here the suite's `MainActor`.
    private func makeRegistry(
        isolation: isolated any Actor = #isolation
    ) -> TaskRegistry<ID> {
        TaskRegistry { work in
            Task {
                _ = isolation
                await work()
            }
        }
    }
}
