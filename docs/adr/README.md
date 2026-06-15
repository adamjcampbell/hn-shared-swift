# Architectural Decision Records

This log records every meaningful architectural decision in the project, in the
order each was made. Records are immutable: a decision that no longer holds is
marked Superseded and points forward to its replacement. Filenames never
change once written.

Format: Michael Nygard's original — Title / Status / Context / Decision /
Consequences. See [adr.github.io](https://adr.github.io/) for the convention.

If you make a new architectural decision, add a new ADR. Copy an existing
file as a template, give it the next number, and add a row to the table
below. Don't edit accepted ADRs in place — write a new one that supersedes
the old.

| #    | Title                                                                                                          | Date       | Status                                                                          |
|------|----------------------------------------------------------------------------------------------------------------|------------|---------------------------------------------------------------------------------|
| 0001 | [One `@Observable` Model as cross-platform source of truth; state is ephemeral](0001-observable-model-source-of-truth.md) | 2026-05-02 | Accepted                                                              |
| 0002 | [Per-platform UI; no UI code sharing](0002-per-platform-ui-no-sharing.md)                                      | 2026-05-02 | Accepted                                                                        |
| 0003 | [`Message` enum funnels all mutations through one entry point](0003-message-enum-single-entry-point.md)        | 2026-05-02 | Accepted                                                                        |
| 0004 | [JSON-snapshot push from `@Observable` to Compose](0004-json-snapshot-push.md)                                 | 2026-05-02 | Superseded by [0007](0007-per-property-typed-jni-thunks.md)                     |
| 0005 | [Strict Swift 6 concurrency + `NonisolatedNonsendingByDefault` (SE-0461)](0005-strict-swift6-concurrency.md)   | 2026-05-02 | Accepted                                                                        |
| 0006 | [`Command` stream (core → UI) for one-shot side-effects](0006-command-stream-side-effects.md)                  | 2026-05-06 | Accepted                                                                        |
| 0007 | [Per-property typed JNI thunks](0007-per-property-typed-jni-thunks.md)                                         | 2026-05-07 | Superseded by [0013](0013-skipfuse-bridgemembers.md)                            |
| 0008 | [`JavaUIActor` pinned to Android's Looper via custom executor](0008-javauiactor-looper-executor.md)            | 2026-05-08 | Superseded by [0013](0013-skipfuse-bridgemembers.md)                            |
| 0009 | [`Observations` AsyncSequence over `withObservationTracking`](0009-observations-asyncsequence.md)              | 2026-05-10 | Superseded by [0013](0013-skipfuse-bridgemembers.md)                            |
| 0010 | [Tuple-return fusion of observe + initial read](0010-tuple-return-observe-read-fusion.md)                      | 2026-05-10 | Superseded by [0013](0013-skipfuse-bridgemembers.md)                            |
| 0011 | [Value-carrying typed `*OnChange` callbacks](0011-value-carrying-onchange-callbacks.md)                        | 2026-05-10 | Superseded by [0013](0013-skipfuse-bridgemembers.md)                            |
| 0012 | [Extension-method bridge experiment via swift-java jextract](0012-extension-method-bridge-jextract.md)         | 2026-05-10 | Superseded by [0013](0013-skipfuse-bridgemembers.md)                            |
| 0013 | [Adopt SkipFuse with `// SKIP @bridgeMembers` for whole-class bridging](0013-skipfuse-bridgemembers.md)         | 2026-05-10 | Accepted                                                                        |
| 0014 | [Pin the bridged `Core` to `@MainActor` on both platforms](0014-mainactor-both-platforms.md)                   | 2026-05-13 | Accepted                                                                        |
| 0015 | [`Engine` actor borrows host executor via `isolation: any Actor`](0015-engine-borrows-host-executor.md)        | 2026-05-13 | Superseded by [0019](0019-core-free-functions-uicore-split.md)                  |
| 0016 | [Single `Engine` actor as sole writer; `Model` is a flat mega-struct](0016-engine-actor-flat-model.md)         | 2026-05-17 | Superseded by [0019](0019-core-free-functions-uicore-split.md)                  |
| 0017 | [Presenter rows projected from `Model`; the package owns the view shape](0017-presenter-rows-in-model.md)      | 2026-05-21 | Accepted                                                                        |
| 0018 | [Localized strings via `Localizable.xcstrings` + a generated `Strings` accessor](0018-localized-strings-catalog-generator.md) | 2026-05-21 | Accepted                                                                        |
| 0019 | [Core from isolation-threaded free functions; vend one `Core`, compose `SendMessageAction` at the app boundary](0019-core-free-functions-uicore-split.md) | 2026-06-01 | Accepted (rev. 2026-06-02); amended by [0025](0025-inject-registry-static-production-isolation.md), [0026](0026-replace-registry-with-latest-slot.md) |
| 0020 | [Ambient `Dependencies` struct; read `date`/`client`/`clock` at the call site](0020-ambient-dependencies-struct.md) | 2026-06-01 | Accepted                                                                        |
| 0021 | [Bind isolation once into a spawn-owning `TaskRegistry`; drop the threaded `isolated` parameters](0021-spawn-owning-task-registry.md) | 2026-06-12 | Superseded by [0025](0025-inject-registry-static-production-isolation.md)        |
| 0022 | [Observe the `TaskRegistry` as a test synchronisation signal; retire `settle`](0022-observable-task-registry-test-signal.md) | 2026-06-12 | Superseded by [0026](0026-replace-registry-with-latest-slot.md)                 |
| 0023 | [Ambient `searchDebounce`; control time by amount, not by clock](0023-ambient-debounce-clock-free-tests.md) | 2026-06-12 | Accepted                                                                        |
| 0024 | [Carry isolation in the work value — `@Sendable @isolated(any)` via `inheritingIsolation`](0024-isolation-carried-work-values.md) | 2026-06-13 | Superseded by [0025](0025-inject-registry-static-production-isolation.md)        |
| 0025 | [Inject the `TaskRegistry` at the composition boundary — static production isolation, dynamic test isolation](0025-inject-registry-static-production-isolation.md) | 2026-06-13 | Superseded by [0026](0026-replace-registry-with-latest-slot.md)                 |
| 0026 | [Replace the `TaskRegistry` with a flat `Tasks` slot registry and free `latest` / `cancel`; async caller-following `apply`](0026-replace-registry-with-latest-slot.md) | 2026-06-15 | Accepted                                                                        |

ADRs 0001–0003, 0005, 0006, 0013, 0014, 0017–0020, 0023, and 0026 together
describe the design as it stands today. ADRs 0004 and 0007–0012 are the
hand-written-bridge evolution that ended at SkipFuse adoption; 0015 and 0016
are the `Engine`-actor era superseded by 0019's free-function core; 0021,
0022, 0024, and 0025 are the `TaskRegistry` era — the spawn-owning registry,
observing it as a test signal, and the Swift 6.3→6.4 isolation workarounds —
superseded by 0026 once `apply` went `async` and a flat `Tasks` slot registry
(free `latest` / `cancel`) replaced the registry. All are preserved as the immutable record of what was
tried and why each step was replaced.
