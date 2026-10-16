# ADR-0021: Foundation-light Android with native platform services

## Status

Accepted (2026-10-16). Supersedes the Android bootstrap in ADR-0014 and
Android resource lookup in ADR-0018. Their MainActor and single-catalog
contracts remain unchanged.

## Context

The original Android runtime packages full Foundation, networking,
internationalization, and ICU. Removing unused symbols alone retains most of
that dependency closure. Embedded Swift cannot currently execute the full
observation/concurrency/bridge contract required by this app. Full Swift with
FoundationEssentials can decode JSON and preserve the actor-based core without
those frameworks.

## Decision

The shared Client executes GET requests through an async Sendable URL-to-
HTTPResponse closure. Responses contain bytes and status, not URLRequest or
URLResponse. Apple platforms use URLSession. Android uses OkHttp callbacks;
Swift cancellation removes the waiting continuation and cancels the same Call.
Both paths normalize cancellation to CancellationError. JSON decoding, Firebase
ranking, Algolia search, and domain projection remain shared Swift.

PlatformSupport owns this boundary and the two platform presentation services:
preferred language tags and time-of-day formatting. It does not own app state.
The existing TaskLocal dependencies, isolation-threaded functions, normalized
Model, Core, Message, Command and SendMessageAction remain the application
architecture. No secondary UI actor or Kotlin model is introduced.

The xcstrings catalog remains the sole authored string store. The generator
emits typed Strings accessors and Android language tables. Apple looks up its
compiled resource bundle; Android selects a table using platform language
preferences. A shared single-pass formatter supports the catalog's validated
string/integer substitutions without interpreting inserted user text.

Android builds use stock Skip-generated Swift JNI and Kotlin peers. The native
runtime is compiled from locked upstream checkouts with a small explicit patch:
FoundationEssentials replaces Foundation; unused Locale/NSNumber dynamic
conversions and the reverse Kotlin-suspend bridge are excluded. The real
Observation registrar and collection/stream bridge remain. JVM runtime classes
are compiled separately; no upstream native AAR payload is consumed.

The Foundation-backed bootstrap is replaced by a process-lifetime main-queue
eventfd registered with Android ALooper. It uses private libdispatch SPI, pinned
to the tested Swift Android SDK. Generated MainActor checks retain their
semantics. This is an explicitly maintained compatibility boundary, not a
supported public Swift API. Toolchain upgrades require device tests.

The packager walks DT_NEEDED and rejects full Foundation, networking,
internationalization, ICU, and unresolved non-system libraries. The app ships
arm64-v8a, as before. Release also runs R8 with JNI/reflection names retained.

## Consequences

- Adding a public observable property still requires only the Swift field and
  regeneration. No per-property handwritten bridge is restored.
- The platform HTTP seam currently supports only GET, which is all this app
  uses. Headers, uploads, and streaming need explicit future contract changes.
- Platform time formats can differ according to native locale conventions;
  domain timestamps and relative-age calculations remain shared.
- Locale/NSNumber values must not be added to the native bridge without
  implementing their Foundation-light conversion. Unsupported dynamic paths
  fail explicitly rather than silently converting incorrectly.
- Kotlin coroutine cancellation of a generated suspend member still does not
  propagate to its Swift Task. This existing limitation is separate from
  cancellation of HTTP requests by the shared core, which does propagate.
- The smaller runtime requires a custom build step, a pinned dependency graph,
  private Dispatch SPI, and end-to-end Android coverage. Returning to full
  Foundation remains an alternative if maintaining that boundary is unsuitable.
