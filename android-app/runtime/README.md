# Foundation-light Android runtime

Gradle `preBuild` depends on `buildSwift`, which invokes `build.py`.
The current script is macOS-only: it uses the macOS Skip executable and
Darwin NDK tools. It expects Swift 6.3.1, Swift Android SDK 6.3.1-RELEASE,
and NDK 27.3.13750724; paths and overrides are in the
[Android README](../README.md).

`build.py` uses the stock, version-locked Skip generator and JVM runtime.
It compiles a reduced native runtime from the SwiftPM checkouts without editing
those checkouts. `foundation-light.patch` is the complete upstream source patch:
Essentials replaces Foundation; unused Locale/NSNumber dynamic conversions are
unavailable. The reverse Kotlin-suspend-to-Swift BridgedJob is not included.

SkipAndroidBridge contributes its Observation registrar, not its Foundation
bootstrap. The small SkipFuse reexport retains generated member bridging.
The JVM SkipFoundation classes remain available for generated Date/URL peers;
their native payload is never packaged.

MainActor runs on Android's UI Looper using libdispatch's private eventfd SPI.
This is deliberately version-pinned, not described as a supported Swift API.
Upgrades require rebuilding and running device isolation/async tests. Do not
replace it with a separate UI actor: generated MainActor checks must still work.

The native packager follows DT_NEEDED with an explicit Android system-library
allowlist, copies and strips the resolved closure, and rejects full Foundation,
FoundationNetworking, FoundationInternationalization, ICU, and unresolved
non-system dependencies. Generated peers, JVM jars and `jniLibs/arm64-v8a`
live under `android-app/build/swift/`. `native-sizes.json` there records
stripped library bytes and dependency edges, not APK size or launch success.
Both build types use that same closure;
release additionally runs R8. No previously exported app AAR is consumed.

APK assets under `third-party/` include licenses, pinned source references,
and `runtime-sources.zip`: the exact modified native sources, upstream JVM
sources and build recipe. Recipients can extract these directly from the APK.
The app's Compose BOM and coroutines versions match the generated JVM projects;
jar-only consumption does not carry upstream dependency constraints.

PlatformSupport supplies the URL-to-HTTPResponse GET seam (bytes/status):
URLSession on Apple, OkHttp callbacks via JNI on Android. Swift cancellation
cancels the Android Call. JSON decoding remains shared. Android language/time
services use platform APIs; string tables remain generated from xcstrings.
TaskLocal dependencies and the real Observation/collection/stream bridges remain.

This custom runtime is a maintained compatibility boundary, not an upstream
supported runtime configuration. Build/device verification is separate; upgrades
must check MainActor isolation, async behavior and JNI/reflection compatibility.
The private OkHttp client must retain its default dispatcher and must not be
shut down: starting a call under the Swift registration lock assumes enqueue
does not synchronously invoke a rejection callback. Revisit the ordering before
introducing a custom executor or client shutdown.
See [ADR-0021](../../docs/adr/0021-foundation-light-platform-services.md).
