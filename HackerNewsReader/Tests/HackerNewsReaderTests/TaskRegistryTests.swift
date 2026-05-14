import Foundation
import Testing
@testable import HackerNewsReader
import HackerNews

@Suite("TaskRegistry")
struct TaskRegistryTests {

    private enum ID: Hashable { case a, b }

    /// A Task that sleeps long enough that the test will always observe
    /// `isCancelled` after the registry cancels it (rather than after
    /// the body has run to completion).
    private func makeLongTask() -> Task<Void, Error> {
        Task { try await Task.sleep(for: .seconds(60)) }
    }

    @Test("assigning a new task cancels the prior task for the same id")
    func setCancelsPriorForSameID() async {
        var registry = TaskRegistry<ID>()
        let first = makeLongTask()
        registry[.a] = first

        let second = makeLongTask()
        registry[.a] = second
        defer { second.cancel() }

        #expect(first.isCancelled)
        #expect(!second.isCancelled)
    }

    @Test("assigning nil cancels and removes the entry")
    func setNilCancelsAndRemoves() async {
        var registry = TaskRegistry<ID>()
        let task = makeLongTask()
        registry[.a] = task

        registry[.a] = nil

        #expect(task.isCancelled)
        #expect(registry[.a] == nil)
    }

    @Test("tasks for independent ids do not interfere")
    func independentIDsDontInterfere() async {
        var registry = TaskRegistry<ID>()
        let taskA = makeLongTask()
        let taskB = makeLongTask()
        registry[.a] = taskA
        registry[.b] = taskB
        defer {
            taskA.cancel()
            taskB.cancel()
        }

        let replacementA = makeLongTask()
        registry[.a] = replacementA
        defer { replacementA.cancel() }

        #expect(taskA.isCancelled)
        #expect(!taskB.isCancelled)
        #expect(!replacementA.isCancelled)
    }
}
