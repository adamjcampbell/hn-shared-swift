import Foundation
import Observation
import Testing
import os
@testable import HackerNewsReader

/// `@MainActor` so `inheritingIsolation` literals inherit the suite's
/// actor — and the registry, whose confinement rests on
/// non-`Sendability`, shares it — mirroring how `makeCore` confines
/// production.
@Suite("TaskRegistry")
@MainActor
struct TaskRegistryTests {

    private enum ID: Hashable { case a, b }

    /// Installs work that parks until cancelled: the sleep never elapses
    /// within a test's lifetime, and cancellation throws it out.
    @discardableResult
    private func runParked(_ id: ID, in registry: TaskRegistry<ID>) -> Task<Void, Never> {
        registry.run(id, inheritingIsolation {
            try? await Task.sleep(for: debounceNeverElapses)
        })
    }

    /// Mirrors `load`'s shape: the work's tail vacates its own slot,
    /// identity-guarded, with the handle carried in a box.
    private func runSelfVacating(
        _ id: ID, in registry: TaskRegistry<ID>,
        work: @escaping () async -> Void = {}
    ) -> Task<Void, Never> {
        final class Handle { var task: Task<Void, Never>? }
        let handle = Handle()
        let task = registry.run(id, inheritingIsolation {
            await work()
            registry.vacate(id, ifStill: handle.task)
        })
        handle.task = task
        return task
    }

    @Test("run cancels the in-flight task for the same id")
    func runCancelsPrior() async {
        let registry = TaskRegistry<ID>()
        let first = runParked(.a, in: registry)

        let second = runParked(.a, in: registry)
        defer { registry.cancelAll() }

        #expect(first.isCancelled)
        #expect(!second.isCancelled)
    }

    @Test("the subscript exposes the in-flight task for joining")
    func subscriptExposesInFlightTask() async {
        let registry = TaskRegistry<ID>()
        let task = runParked(.a, in: registry)
        defer { registry.cancelAll() }

        // A caller wanting join-instead-of-duplicate awaits this.
        #expect(registry[.a] == task)
        #expect(registry[.b] == nil)
    }

    @Test("a finished task vacates its slot, so a joiner would start fresh")
    func completionVacatesSlot() async {
        let registry = TaskRegistry<ID>()
        let task = runSelfVacating(.a, in: registry)

        await task.value

        #expect(registry[.a] == nil)
    }

    @Test("a replaced task finishing late does not vacate the replacement's slot")
    func staleVacateDoesNotClobberReplacement() async {
        let registry = TaskRegistry<ID>()
        let first = runSelfVacating(.a, in: registry) {
            try? await Task.sleep(for: debounceNeverElapses)
        }
        let second = runParked(.a, in: registry)
        defer { registry.cancelAll() }

        // The cancelled first task unparks and runs its vacate against a
        // slot that now belongs to the second task.
        await first.value

        #expect(registry[.a] == second)
    }

    @Test("cancel cancels and removes the entry")
    func cancelCancelsAndRemoves() async {
        let registry = TaskRegistry<ID>()
        let task = runParked(.a, in: registry)

        registry.cancel(.a)
        await task.value

        #expect(task.isCancelled)
        #expect(registry[.a] == nil)
    }

    @Test("tasks for independent ids do not interfere")
    func independentIDsDontInterfere() async {
        let registry = TaskRegistry<ID>()
        let taskA = runParked(.a, in: registry)
        let taskB = runParked(.b, in: registry)
        defer { registry.cancelAll() }

        let replacementA = runParked(.a, in: registry)

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

        let task = runSelfVacating(.a, in: registry)
        #expect(fired.withLock { $0 })
        #expect(registry[.a] == task)

        // Completion vacates the slot — the transition `waitUntil` rides on.
        await task.value
        #expect(registry[.a] == nil)
    }

    @Test("cancelAll cancels every in-flight task")
    func cancelAllCancelsEverything() async {
        let registry = TaskRegistry<ID>()
        let taskA = runParked(.a, in: registry)
        let taskB = runParked(.b, in: registry)

        registry.cancelAll()

        #expect(taskA.isCancelled)
        #expect(taskB.isCancelled)
    }
}
