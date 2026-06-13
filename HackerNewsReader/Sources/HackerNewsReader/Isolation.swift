/// Returns `operation` as a `Sendable` value that carries its formation
/// context's isolation — upgrading non-`Sendable` work to `Sendable` by
/// inheriting the actor context.
///
/// `@_inheritActorContext` makes the closure literal inherit the
/// enclosing isolation into the `@isolated(any)` value, which is what
/// legalises its non-`Sendable` captures under `@Sendable`: the closure
/// can only ever run on the actor those captures belong to. `Task`
/// enqueues an `@isolated(any)` function on its carried isolation
/// (SE-0431), so the operation runs — and resumes after its internal
/// suspensions — on the actor it was formed on, no matter where it is
/// later spawned or awaited from. That carriage is the property
/// `nonisolated(nonsending)` work lacks: nonsending runs on the
/// *caller's* isolation, which evaporates when a calling chain loses
/// its pin.
///
/// In a context isolated to a global actor the inheritance is
/// unconditional. In an isolated-*parameter* context the literal must
/// strongly capture the parameter (`_ = isolation`, SE-0420); forgetting
/// the capture is a compile error whenever the operation touches
/// non-`Sendable` state, so the mistake cannot ship silently.
///
/// `@_inheritActorContext` is underscored — outside the evolution
/// process, semantics revisable. ADR-0024 records why authoring against
/// it is accepted here and the endurance gate that protects the bet;
/// the dormant "closure isolation control" pitch's `@inheritsIsolation`
/// is the stable spelling this helper dissolves into if it ever ships.
///
/// - Parameter operation: The work to bind to the current isolation.
/// - Returns: `operation`, `Sendable` and carrying the current
///   isolation.
func inheritingIsolation(
    @_inheritActorContext _ operation: @Sendable @escaping @isolated(any) () async -> Void
) -> @Sendable @isolated(any) () async -> Void {
    operation
}
