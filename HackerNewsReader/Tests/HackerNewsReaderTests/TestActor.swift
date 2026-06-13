/// Per-test isolation. Each `TestActor` instance has its own default
/// actor executor, so a fixture isolated to a fresh instance serialises
/// its message handling and spawned tasks there, while different tests
/// parallelise across instances.
actor TestActor {}
