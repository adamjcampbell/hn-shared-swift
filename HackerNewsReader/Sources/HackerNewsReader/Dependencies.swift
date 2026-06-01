import Foundation
import HackerNews

/// Package-wide ambient dependencies, propagated via one `@TaskLocal`.
///
/// Modelled on `pointfreeco/swift-dependencies` (values read at the call
/// site rather than threaded through signatures) without adopting the
/// library — its macros and runtime don't fit Skip's Android target.
/// Three fixed, single-module injectables, so a plain struct in one
/// `@TaskLocal` beats a keyed `DependencyValues` dictionary: typed reads,
/// no erasure, no per-key boilerplate.
///
/// Production reads see the live defaults (`Date()`, `Client()`,
/// `ContinuousClock()`); no `withValue` is needed because the defaults
/// are the live values. Tests override via
/// `Dependencies.$current.withValue(…) { … }` — `withCore` does this
/// internally so the listener `Task` and message handlers `makeCore`
/// spawns inherit the same pinned deps. Override a subset by copying and
/// mutating: `var d = Dependencies.current; d.date = .constant(t)`.
struct Dependencies: Sendable {
    var date = DateGenerator { Date() }
    var client = Client()
    var clock: any Clock<Duration> = ContinuousClock()

    @TaskLocal static var current = Dependencies()
}

/// Sendable wrapper around a `() -> Date` closure. Mirrors
/// `swift-dependencies`' `DateGenerator` so call sites read the same
/// way (`Dependencies.current.date.now`).
struct DateGenerator: Sendable {
    private let generate: @Sendable () -> Date

    init(_ generate: @escaping @Sendable () -> Date) {
        self.generate = generate
    }

    /// Current time. Reads via the wrapped closure.
    var now: Date { generate() }

    /// A generator that always returns `now`. Useful for pinning time in
    /// tests by overriding just the `date` field of ``Dependencies``.
    static func constant(_ now: Date) -> Self { Self { now } }
}
