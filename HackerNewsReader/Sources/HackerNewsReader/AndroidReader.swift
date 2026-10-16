import Observation

/// Main-thread JNI entry points for the Android application.
public final class AndroidReader: Sendable {
    let storage: ReaderStorage

    public init() {
        storage = MainActor.assumeIsolated { ReaderStorage(core: makeAppCore()) }
    }

    @MainActor init(core: Core) { storage = ReaderStorage(core: core) }

    public func start(_ message: Message, _ completion: sending @escaping (Bool) -> Void) -> Int64 {
        MainActor.assumeIsolated { storage.start(message, completion: completion) }
    }

    public func cancel(_ token: Int64) {
        MainActor.assumeIsolated { storage.cancel(token) }
    }

    public func observeCommands(_ callback: sending @escaping () -> Void) -> Int64 {
        MainActor.assumeIsolated { storage.observeCommands(callback) }
    }

    public func takeCommand() -> Command? {
        MainActor.assumeIsolated { storage.commands.isEmpty ? nil : storage.commands.removeFirst() }
    }

    public func close() {
        MainActor.assumeIsolated { storage.close() }
    }
}

@MainActor
final class ReaderStorage {
    private var core: Core?
    private var nextToken: Int64 = 0
    private var closed = false
    private var observations: [Int64: ReaderObservation] = [:]
    private var operations: [Int64: (Task<Void, Never>, (Bool) -> Void)] = [:]
    private var commandTask: Task<Void, Never>?
    private var commandCallback: (() -> Void)?
    private var commandToken: Int64?
    var commands: [Command] = []

    var model: Model {
        precondition(!closed, "Reader is closed")
        return core!.model
    }

    init(core: Core) {
        self.core = core
        commandTask = Task { [weak self, stream = core.commands] in
            for await command in stream {
                guard let self, !self.closed else { return }
                guard self.commandCallback != nil else { continue }
                self.commands.append(command)
                self.commandCallback?()
            }
        }
    }

    func observe(read: @escaping () -> Void, callback: @escaping () -> Void) -> Int64 {
        precondition(!closed, "Reader is closed")
        nextToken += 1
        observations[nextToken] = ReaderObservation(read: read, callback: callback)
        return nextToken
    }

    func start(_ message: Message, completion: @escaping (Bool) -> Void) -> Int64 {
        precondition(!closed, "Reader is closed")
        nextToken += 1
        let token = nextToken
        let action = SendMessageAction(core!)
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await action.run(message)
            self?.operations.removeValue(forKey: token)?.1(true)
        }
        operations[token] = (task, completion)
        return token
    }

    func observeCommands(_ callback: @escaping () -> Void) -> Int64 {
        precondition(!closed && commandCallback == nil, "Only one command consumer is supported")
        nextToken += 1
        commandToken = nextToken
        commandCallback = callback
        return nextToken
    }

    func cancel(_ token: Int64) {
        observations.removeValue(forKey: token)?.cancel()
        if let (task, completion) = operations.removeValue(forKey: token) {
            task.cancel()
            completion(false)
        }
        if commandToken == token {
            commandToken = nil
            commandCallback = nil
            commands.removeAll()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        observations.values.forEach { $0.cancel() }
        observations.removeAll()
        commandTask?.cancel()
        commandTask = nil
        commandCallback = nil
        commandToken = nil
        commands.removeAll()
        core?.cancelAll()
        core = nil
        let pending = operations.values
        operations.removeAll()
        for (task, completion) in pending {
            task.cancel()
            completion(false)
        }
    }
}

@MainActor
private final class ReaderObservation {
    private var read: (() -> Void)?
    private var callback: (() -> Void)?

    init(read: @escaping () -> Void, callback: @escaping () -> Void) {
        self.read = read
        self.callback = callback
        arm()
    }

    private func arm() {
        guard let read else { return }
        withObservationTracking { read() } onChange: { [weak self] in
            // Observation fires at willSet; read and rearm on the next actor turn.
            Task { @MainActor [weak self] in
                guard let self, self.read != nil else { return }
                self.arm()
                self.callback?()
            }
        }
    }

    func cancel() {
        read = nil
        callback = nil
    }
}
