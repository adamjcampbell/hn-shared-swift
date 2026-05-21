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
