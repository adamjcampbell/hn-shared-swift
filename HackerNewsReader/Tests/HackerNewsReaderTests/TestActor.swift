import Dispatch

/// Per‑test isolation. Each `TestActor` owns a `DispatchSerialQueue`
/// exposed as its `unownedExecutor`. The `withCore` fixture is isolated
/// to one, so `makeCore`'s `#isolation` binds here and its message
/// handling, listener Task, and observation callbacks all run on this
/// serial queue. Different `TestActor`s run on different queues, so
/// tests parallelise across instances.
public actor TestActor {
    private nonisolated let queue: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    public init(label: String = "TestActor.queue") {
        self.queue = DispatchSerialQueue(label: label)
    }
}
