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
| 0015 | [`Engine` actor borrows host executor via `isolation: any Actor`](0015-engine-borrows-host-executor.md)        | 2026-05-13 | Accepted                                                                        |
| 0016 | [Single `Engine` actor as sole writer; `Model` is a flat mega-struct](0016-engine-actor-flat-model.md)         | 2026-05-17 | Accepted                                                                        |

ADRs 0001–0003, 0005, 0006, and 0013–0016 together describe the design as it
stands today. ADRs 0004 and 0007–0012 are the hand-written-bridge evolution
that ended at SkipFuse adoption; they are preserved as the immutable record
of what was tried and why each step was replaced.
