import Dispatch

/// Per‑test isolation. Each `TestActor` owns a `DispatchSerialQueue`
/// exposed as its `unownedExecutor` (SE-0392). Pass it as `isolation:`
/// when constructing an `AppCore` so the AppCore's methods, listener
/// Tasks, and observation callbacks all run on the same serial queue —
/// different `TestActor`s run on different queues, so tests parallelise
/// across instances.
///
/// `settle()` enqueues a continuation-resume at the back of the queue
/// (Point‑Free Video #362 pattern). Awaiting it drains every pending
/// job — listener-Task resumption, fetch / commit Tasks spawned by
/// `sendEvent`, post-`clock.sleep` continuations — deterministically.
/// Replaces `Task.megaYield()`.
public actor TestActor {
    private nonisolated let queue: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    public init(label: String = "TestActor.queue") {
        self.queue = DispatchSerialQueue(label: label)
    }

    public nonisolated func settle() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
