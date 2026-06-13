/// Per-test isolation. Each `TestActor` instance has its own default
/// actor executor, so the `withCore` fixture (isolated to a fresh
/// instance) binds `makeCore`'s `#isolation` here, its message handling
/// and spawned tasks serialise on this instance, and different tests
/// parallelise across instances.
///
/// Before Swift 6.4 this installed a custom `DispatchSerialQueue` as
/// `unownedExecutor` — needed for the old `runPending()` drain and to
/// dodge swiftlang/swift#88993 (instance-isolated continuations resuming
/// off-executor). Both are gone (the drain in ADR-0023, the bug fixed in
/// 6.4), so the default actor executor suffices.
actor TestActor {}
