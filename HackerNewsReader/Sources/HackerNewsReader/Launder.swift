/// Returns `operation` with its formation context's isolation captured
/// into the `@isolated(any)` value — `@_inheritActorContext` makes the
/// closure literal inherit the enclosing isolation, which is what
/// legalises its non-`Sendable` captures under `@Sendable`.
///
/// The carried isolation is what `Task(operation:)` enqueues on
/// (SE-0431), so a laundered closure runs — and resumes after internal
/// suspensions — on the actor it was formed on, no matter where it is
/// later spawned from. In an isolated-parameter context the literal must
/// still capture the parameter (`_ = isolation`, SE-0420); forgetting it
/// is a compile error whenever the closure touches non-`Sendable` state.
///
/// PROBE: `@_inheritActorContext` is an underscored attribute the
/// project has twice declined to author against (ADR-0019, ADR-0021);
/// this branch exists to measure what accepting it buys.
func launder(
    @_inheritActorContext operation: @Sendable @escaping @isolated(any) () async -> Void
) -> @Sendable @isolated(any) () async -> Void {
    operation
}
