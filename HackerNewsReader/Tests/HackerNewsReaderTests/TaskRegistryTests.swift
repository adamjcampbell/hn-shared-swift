import Foundation
import Observation
import Testing
import os
@testable import HackerNewsReader

/// `@MainActor` so the suite's `Task` literals — and the registry, whose
/// confinement rests on non-`Sendability` — share one actor, mirroring
/// how `makeCore` confines production.
@Suite("TaskRegistry")
@MainActor
struct TaskRegistryTests {

    private enum ID: Hashable { case a, b }

    /// Parks until cancelled: the sleep never elapses within a test's
    /// lifetime, and cancellation throws it out.
    private func parked() -> Task<Void, Never> {
        Task { try? await Task.sleep(for: debounceNeverElapses) }
    }

    /// Mirrors `load`'s spawn shape: the task vacates its own slot from
    /// its synchronous tail, identity-guarded.
    private func selfVacating(
        _ id: ID, in registry: TaskRegistry<ID>,
        work: @escaping () async -> Void = {}
    ) -> Task<Void, Never> {
        var handle: Task<Void, Never>?
        let task = Task {
            await work()
            registry.vacate(id, ifStill: handle)
        }
        handle = task
        registry.replace(id, with: task)
        return task
    }

    @Test("replace cancels the in-flight task for the same id")
    func replaceCancelsPrior() async {
        let registry = TaskRegistry<ID>()
        let first = parked()
        registry.replace(.a, with: first)

        let second = parked()
        registry.replace(.a, with: second)
        defer { registry.cancelAll() }

        #expect(first.isCancelled)
        #expect(!second.isCancelled)
    }

    @Test("the subscript exposes the in-flight task for joining")
    func subscriptExposesInFlightTask() async {
        let registry = TaskRegistry<ID>()
        let task = parked()
        registry.replace(.a, with: task)
        defer { registry.cancelAll() }

        // A caller wanting join-instead-of-duplicate awaits this.
        #expect(registry[.a] == task)
        #expect(registry[.b] == nil)
    }

    @Test("a finished task vacates its slot, so a joiner would start fresh")
    func completionVacatesSlot() async {
        let registry = TaskRegistry<ID>()
        let task = selfVacating(.a, in: registry)

        await task.value

        #expect(registry[.a] == nil)
    }

    @Test("a replaced task finishing late does not vacate the replacement's slot")
    func staleVacateDoesNotClobberReplacement() async {
        let registry = TaskRegistry<ID>()
        let first = selfVacating(.a, in: registry) {
            try? await Task.sleep(for: debounceNeverElapses)
        }
        let second = parked()
        registry.replace(.a, with: second)
        defer { registry.cancelAll() }

        // The cancelled first task unparks and runs its vacate against a
        // slot that now belongs to the second task.
        await first.value

        #expect(registry[.a] == second)
    }

    @Test("cancel cancels and removes the entry")
    func cancelCancelsAndRemoves() async {
        let registry = TaskRegistry<ID>()
        let task = parked()
        registry.replace(.a, with: task)

        registry.cancel(.a)
        await task.value

        #expect(task.isCancelled)
        #expect(registry[.a] == nil)
    }

    @Test("tasks for independent ids do not interfere")
    func independentIDsDontInterfere() async {
        let registry = TaskRegistry<ID>()
        let taskA = parked()
        let taskB = parked()
        registry.replace(.a, with: taskA)
        registry.replace(.b, with: taskB)
        defer { registry.cancelAll() }

        let replacementA = parked()
        registry.replace(.a, with: replacementA)

        #expect(taskA.isCancelled)
        #expect(!taskB.isCancelled)
        #expect(!replacementA.isCancelled)
    }

    @Test("registration and vacate are observable through the subscript")
    func mutationsAreObservable() async {
        let registry = TaskRegistry<ID>()

        let fired = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = registry[.a]
        } onChange: {
            fired.withLock { $0 = true }
        }

        let task = selfVacating(.a, in: registry)
        #expect(fired.withLock { $0 })
        #expect(registry[.a] == task)

        // Completion vacates the slot — the transition `waitUntil` rides on.
        await task.value
        #expect(registry[.a] == nil)
    }

    @Test("cancelAll cancels every in-flight task")
    func cancelAllCancelsEverything() async {
        let registry = TaskRegistry<ID>()
        let taskA = parked()
        let taskB = parked()
        registry.replace(.a, with: taskA)
        registry.replace(.b, with: taskB)

        registry.cancelAll()

        #expect(taskA.isCancelled)
        #expect(taskB.isCancelled)
    }
}
