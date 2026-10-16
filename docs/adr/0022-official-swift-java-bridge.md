# ADR-0022: Replace Skip with official Swift–Java and generated model adapters

## Status

Accepted (2026-10-16). Supersedes ADR-0013
and the Skip bridge, patched runtime and cancellation limitations in ADR-0021.
ADR-0021's Foundation-light transport, single-catalog localization and pinned
private Looper SPI remain.

## Context

The shared Swift model and free-function core do not require a translated UI
or a general-purpose Skip runtime. Official Swift–Java can provide typed JNI
peers while a small source generator supplies the app's observation boundary.
The replacement must preserve Swift 6 isolation, native UI-thread reads,
TaskLocal dependencies, shared JSON decoding and one authoritative Model.
Kotlin coroutine cancellation must reach the Swift operation and its fetch.

## Decision

Pin official swift-java to `301e3da710ede7af93e798f1ce1c7950715a5748`
and retain JNI core `b440a0be98381550cf189c903782e817619ffa05` in the lockfile.
Use that same JNI-core checkout for the Android native build. Remove Skip
dependencies, CLI requirements, source patches, old SwiftJNI and kotlin-reflect.
Restore the two controlled runtime lockfiles into the generator and native
SwiftPM roots and build with forced resolved versions. Version-2 locks omit
path-dependent origin hashes. Include all three actual graphs in APK notices.

Use SwiftParser in `scripts/generate-android.swift` to discover public Model
fields and generate MainActor-checked native accessors, per-property Observation
invalidation subscriptions and value projections. Explicit property types are
required; unsupported types fail generation. Official `jextract --mode jni`
generates typed Java peers and synchronous JNI thunks. App, Observation and
core code remain Swift 6; only generated synchronous thunks use Swift 5 mode.

Writable properties support String, Int, Int64, Bool and Double. Read-only
properties additionally support Date, String?, [String], and the three value
projections as plain, optional or array values. Other shapes fail before either
output is written. Optional/array setters and primitive optionals require
explicit future JNI conversions; they are not advertised as supported.

Copy Message into Swift synchronously before suspension. Native task handles
connect Kotlin `suspendCancellableCoroutine` to Swift cancellation. The shared
core cancellation handler cancels the underlying fetch. Do not use the raw-peer
async future path, which would extend peer lifetimes across suspension.
After cancellation, clear loading only if the task still owns its registry slot;
an older cancelled request must not clear a newer request's loading status.

Kotlin stores Compose revision counters and immutable value copies, not a second
authoritative mutable app state. Revision reads register Compose dependencies;
getters read the latest Swift state, not snapshot-versioned state. Observation
rearms and invalidates on the next MainActor turn because callbacks fire at
willSet. Project Date to epoch-seconds Double. Copy native values inside confined
arenas and dispose them before leaving the scopes.

Adapt commands through official typed Java peers to Kotlin Flow. The native
command pump persists across Activity collector cancellation and recollection
until Core closes. Only one consumer is supported; commands without a subscriber
are dropped. Core explicitly closes observations, tasks, peers and arenas;
production ownership remains Application lifetime.
Check closure before each native command read: sending can resume a collector
inline, and that collector can synchronously close the reader.

Keep URLSession on Apple and OkHttp on Android, with official SwiftJava for JNI
callbacks. URL construction and JSON decoding remain shared. Preserve the
FoundationEssentials dependency boundary and the private libdispatch UI Looper
bootstrap pinned to Swift/Android SDK 6.3.1; do not introduce another UI actor.

## Consequences

- Adding a supported public Model field regenerates both accessors and the
  Compose adapter without handwritten per-field glue. New type families still
  require explicit generator support.
- The app owns its observation, coroutine and resource-lifetime adapters rather
  than relying on Skip's collection/stream runtime. Confined peers must not
  escape into UI state.
- Kotlin revision invalidation is not Compose snapshot isolation for native
  state. Consumers must not treat revision numbers as historical snapshots.
- The build produces Java peers, Kotlin adapters, SwiftJava.jar and a checked
  native dependency closure. APK notices contain upstream references, licenses
  and the per-root lockfiles, not the previous patched Skip source archive.
- Upstream thread-safety annotations reference desktop JFR labels. R8 ignores
  only the missing `jdk.jfr.Description` and `jdk.jfr.Label` annotation types;
  JNI/runtime classes retain their names.

## Validation

Local checks on 2026-10-16:

- 60 host Swift tests pass, including in-flight cancellation, replacement
  ownership, observation projections, command detach/reattach and explicit close.
  The loading-status regression fails before the ownership-aware cleanup.
- iOS simulator build and live feed launch pass.
- Debug, Android test APK and R8 release builds pass using the default pinned
  generator. An unchanged Gradle build marks `buildSwift` up-to-date.
- Four instrumentation tests pass on an arm64 API 36 emulator: Unicode and
  Compose invalidation, live MainActor actions, 25 explicit-close/GC cycles
  with copied values, and coroutine cancellation without closing the reader.
- A temporary live-network probe passes with an Unconfined command collector
  closing Core during delivery. It is not retained in the offline test suite;
  this is functional coverage, not an ASan result or reproduced memory fault.
- The release APK launches with live Firebase and Algolia data. Swipe changes
  unread count from 50 to 49; pagination replaces the loading row with appended
  results. URL presentation still works after Activity recreation by rotation.
- A temporary added public String property generates native read/write/observe
  accessors and the Kotlin Compose property without per-field handwritten glue.
- The generator contract test typechecks a 24-property Swift fixture, extracts
  official Java peers and compiles Kotlin against them. An incorrect Boolean
  setter is rejected; eight unsupported shapes fail without modifying outputs.
  Nested plain/optional/array projections fail compilation without arena
  forwarding and pass with it. Oracle confirmed all final review findings resolved.
- Packaged dependency inspection finds no Skip, old SwiftJNI, full Foundation,
  FoundationNetworking, FoundationInternationalization or ICU payload.

Single arm64 R8 APKs, both signed with the same local debug key for emulator
checks; decimal MB. Baseline is the saved Foundation-light Skip APK, not the
original full-Foundation build. Its unsigned source is 13,474,710 bytes:

| Measurement | Skip baseline | Official Swift–Java |
|---|---:|---:|
| APK bytes | 13,494,273 | 9,851,635 |
| Packaged native bytes, uncompressed | 19,422,048 | 19,783,872 |
| APK + extracted native estimate | 32.92 MB | 29.64 MB |

Native bytes increase slightly; APK reduction also reflects removal of Skip
JVM libraries and the patched-source archive. The estimate is not measured
installation size or resident memory. Emulator checks do not establish physical
device compatibility. No CI, merge or deployment result is implied.

Rapid adb text entry intermittently loses characters in both the prior Skip
APK and this migration. Four fresh-process baseline trials for `Swift` yield
`Swft`, `S`, `Sift`, and `Swift`. This establishes a pre-existing issue, not
its cause; the unchanged text-binding helper is not fixed in this migration.
