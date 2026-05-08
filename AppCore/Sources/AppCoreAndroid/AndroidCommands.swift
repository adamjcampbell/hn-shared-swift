#if canImport(Android)
import Foundation
import AppCore

/// Reusable outbound async-stream pump. Consumes an `AsyncStream<C>`,
/// encodes each value to JSON via `JNICoder`, and delivers to a
/// `CommandSink`.
///
/// Replaces the inline `commandTask` shape from the previous
/// `AndroidBridge` actor. The single-iterator constraint of `AsyncStream`
/// is respected — there's one consumer per platform binary, and the
/// model's continuation outlives this pump (so `stop()` leaves the
/// stream open for a re-`start()`).
@JavaUIActor
public final class AndroidCommands<C: Encodable & Sendable> {
    private let stream: AsyncStream<C>
    private let sink: any CommandSink
    private var task: Task<Void, Never>?

    public init(stream: AsyncStream<C>, sink: any CommandSink) {
        self.stream = stream
        self.sink = sink
    }

    public func start() {
        task?.cancel()
        let stream = self.stream
        let sink = self.sink
        task = Task {
            for await command in stream {
                sink.deliverCommand(commandJSON: JNICoder.encode(command))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
#endif
