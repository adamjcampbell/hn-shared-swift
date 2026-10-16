# Foundation-light Android runtime

Gradle `preBuild` depends on `buildSwift`, which invokes `build.py`.
The script is macOS-only: it uses Xcode's host SwiftParser/SwiftSyntax
libraries and Darwin NDK tools. It requires Swift 6.3.1, Swift Android SDK
6.3.1-RELEASE and NDK 27.3.13750724. Paths and overrides are in the
[Android README](../README.md). Local build, emulator and APK measurements
are recorded in [ADR-0022](../../docs/adr/0022-official-swift-java-bridge.md).

## Generation and compilation

The package pins official swift-java to
`301e3da710ede7af93e798f1ce1c7950715a5748`; the lockfile resolves JNI core to
`b440a0be98381550cf189c903782e817619ffa05`. The native build shares that exact
JNI-core checkout through `SWIFT_JAVA_JNI_CORE_PATH`.
No Skip dependencies, CLI, source patches, old SwiftJNI or kotlin-reflect are needed.
The controlled `swift-java.Package.resolved` and `android.Package.resolved`
files are restored into their actual build roots and enforced with
`--force-resolved-versions`. The app root graph is also enforced. All three
actual lockfiles are included in the APK notices. Version-2 runtime locks omit
origin hashes that depend on absolute local package paths.

1. `scripts/generate-android.swift` uses SwiftParser to discover public
   `Model` properties. It emits `AndroidReader.generated.swift` and Kotlin
   `Model.kt`: checked MainActor accessors, Observation invalidation subscriptions,
   and value projections. Explicit property types are required; unsupported
   types fail before either output is written. Writable scalars are String,
   Int, Int64, Bool and Double. See ADR-0022 for the read-only type boundary.
2. The pinned `swift-java jextract --mode jni` generates typed Java peers and
   synchronous Swift JNI thunks for AndroidReader, its generated projections,
   Message, Command and Strings. `SWIFT_JAVA_TOOL` can supply the same pinned tool.
3. App, Observation and core code compile in Swift 6 mode. Only generated
   synchronous JNI thunks use Swift 5 mode. They copy Message into Swift
   before suspension; no raw-peer async future path is used.
4. Official SwiftKitCore Java sources and generated peers compile into
   `SwiftJava.jar` with Java release 17. Native libraries, Java peers, Kotlin
   adapters and the jar live under `android-app/build/swift/`.

## Ownership and cancellation

Kotlin stores Compose revision counters and immutable value copies, not
authoritative mutable app state. Accessors read Swift's latest state, not
snapshot-versioned state tied to a revision. Observation fires at willSet;
the subscription rearms and invalidates on the next MainActor turn.
Native values are copied inside confined `SwiftArena` scopes and disposed
before those scopes end. Date values project to epoch-seconds Double.

Kotlin `suspendCancellableCoroutine` maps cancellation to a native task handle.
The Swift operation and shared-core cancellation handler carry cancellation
through to the underlying fetch. Commands travel through typed official Java
peers into Kotlin Flow values. The native stream pump remains alive until
Core closes, including across Activity collector cancellation and recollection.
Only one consumer is supported; without a subscriber, commands are dropped.
Core explicitly closes model subscriptions, tasks, native peers and arenas.
Production Core has Application lifetime.

PlatformSupport supplies the GET-only URL-to-HTTPResponse seam (bytes/status):
URLSession on Apple, OkHttp callbacks through official SwiftJava on Android.
Swift cancellation cancels the Android Call. JSON decoding remains shared.
Android language/time services use platform APIs; string tables remain generated
from xcstrings. TaskLocal dependencies and real Swift Observation remain.

## Packaging and compatibility boundary

MainActor still runs on Android's UI Looper using private libdispatch eventfd
SPI, unchanged from [ADR-0021](../../docs/adr/0021-foundation-light-platform-services.md).
This is not a supported public Swift API. Keep MainActor checks; do not replace
them with a separate UI actor. Toolchain upgrades require device tests.

The packager walks DT_NEEDED with an Android system-library allowlist, copies
and strips the resolved closure, and rejects full Foundation,
FoundationNetworking, FoundationInternationalization, ICU, Skip, SwiftJNI and
unresolved non-system dependencies. `native-sizes.json` records stripped native
bytes and dependency edges, not APK size or launch success. Both build types
use that closure; release additionally runs R8. No exported app AAR is consumed.

APK `assets/third-party/` includes upstream licenses/notices and all build-root lockfiles,
not the former patched Skip runtime source archive. See `NOTICE.txt` for sources.

The private OkHttp client must retain its default dispatcher and must not be
shut down: starting a call under the Swift registration lock assumes enqueue
does not synchronously invoke a rejection callback. Revisit the ordering before
introducing a custom executor or client shutdown.

See [ADR-0022](../../docs/adr/0022-official-swift-java-bridge.md) for the
replacement decision and validation results.
