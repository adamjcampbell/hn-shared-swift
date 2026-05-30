import Foundation

/// Package-wide ambient dependencies, propagated via `@TaskLocal`.
///
/// Modelled on `pointfreeco/swift-dependencies` (`DateGenerator`,
/// `@Dependency(\.date.now)`) without adopting the library itself —
/// the macros and runtime infrastructure don't fit Skip's Android
/// Swift target. The TaskLocal approach has the same ergonomics for
/// our single use case (`Date` injection in tests) at the cost of one
/// type and one stored `@TaskLocal`.
///
/// Reads at production sites default to wall-clock `Date()`. Tests
/// override via `Dependencies.$date.withValue(.constant(pinned)) { … }`
/// — `withEngine` does this internally so test bodies see a stable
/// `now` across `bind()`-spawned listener tasks and message handlers.
enum Dependencies {
    @TaskLocal static var date = DateGenerator { Date() }

    /// Logs `Model` changes around each `Engine` mutation. Injected like
    /// `date`: production gets `.none` (no-op), tests inject a
    /// snapshotting logger via `withEngine`.
    @TaskLocal static var changeLogger = ChangeLogger.none
}

/// Hook for logging how `Model` changes around a unit of `Engine` work.
///
/// `capture` is handed the model before the work and returns a finisher
/// to run after it (capturing the before-state for a diff), or `nil` to
/// do nothing. Production injects ``none``; tests inject a logger built
/// on DebugSnapshots' `snap` / `_logChanges` — so that machinery, and
/// the import, stay out of `Engine`.
struct ChangeLogger: Sendable {
    var capture: @Sendable (Model) -> ((_ label: String) -> Void)?

    /// Does nothing — never snapshots, never logs.
    static let none = ChangeLogger { _ in nil }
}

/// Sendable wrapper around a `() -> Date` closure. Mirrors
/// `swift-dependencies`' `DateGenerator` so call sites read the same
/// way (`Dependencies.date.now`).
struct DateGenerator: Sendable {
    private let generate: @Sendable () -> Date

    init(_ generate: @escaping @Sendable () -> Date) {
        self.generate = generate
    }

    /// Current time. Reads via the wrapped closure.
    var now: Date { generate() }

    /// A generator that always returns `now`. Useful for tests:
    /// `Dependencies.$date.withValue(.constant(fixedDate)) { … }`.
    static func constant(_ now: Date) -> Self { Self { now } }
}
