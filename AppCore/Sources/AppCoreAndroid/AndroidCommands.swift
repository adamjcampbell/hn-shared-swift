#if canImport(Android)
import Foundation
import AppCore

/// Outbound async-stream pump for `AppCommand`. Consumes
/// `AppModel.commands` and dispatches each command to the matching
/// typed method on a `CommandSink`. No JSON crosses the JNI boundary —
/// the case switch lives here so the wire is plain primitives.
///
/// The single-iterator constraint of `AsyncStream` is respected — there's
/// one consumer per platform binary, and the model's continuation outlives
/// this pump (so `stop()` leaves the stream open for a re-`start()`).
@JavaUIActor
public final class AndroidCommands {
    private let stream: AsyncStream<AppCommand>
    private let sink: any CommandSink
    private var task: Task<Void, Never>?

    public init(stream: AsyncStream<AppCommand>, sink: any CommandSink) {
        self.stream = stream
        self.sink = sink
    }

    public func start() {
        task?.cancel()
        task = Task { [stream, sink] in
            for await command in stream {
                switch command {
                case .presentURL(let value):
                    sink.presentURL(value: value)
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
#endif
