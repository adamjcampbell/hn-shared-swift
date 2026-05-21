# ADR-0018: Localized strings via `Localizable.xcstrings` + a generated `Strings` accessor

## Status

Accepted (2026-05-21).

## Context

User-visible strings need to be localizable and identical across iOS
and Android. The Apple-native ergonomics for catalog-backed strings —
`String(localized:bundle:)`, `LocalizationValue`, `Bundle.module` at
argument position, `String.LocalizationValue` interpolations — are
the obvious starting point on iOS. None of them resolve reliably
through skip-foundation on Android:

- `Bundle.module` works on Apple platforms as a SwiftPM-synthesised
  static, but on Skip's Android target a `typealias Bundle =
  AndroidBundle` hides the SwiftPM extension at argument position.
- `String(localized: "key", bundle: …)` and the related
  `LocalizationValue` initialisers don't route to the catalog on
  Android — the lookup returns the source string verbatim.
- `AttributedString(localized:)` has the same gap.

Earlier attempts to ship `String(localized:)` from the cross-platform
package and read it on Android failed at the bridge; the working note
in this repo's memory captures the same conclusion
([feedback_skip_localization_limitations]).

The cross-platform alternatives were:

- **Plain Swift literals everywhere.** No catalog, no localization,
  but lockstep across platforms. Rejected — the app already wants
  localizable copy, and committing to "no localization ever" closes
  off a basic affordance.
- **Catalogs per platform.** An `xcstrings` on iOS and an Android
  `strings.xml` written by hand or by a converter. Rejected — two
  sources of truth, with the merge burden falling on the author.
- **Single catalog, generated accessor.** One `xcstrings` drives both
  platforms; the accessor uses primitives that *do* bridge through
  skip-foundation. Chosen.

## Decision

`Localizable.xcstrings` is the single source of truth for user-visible
strings.

`generate-strings.swift` regenerates `Strings.swift` from the catalog.
The generator:

- Parses each catalog entry and infers a Swift signature from its
  format specifiers — `%@` → `String`, `%lld` → `Int`, `%d` → `Int`,
  positional specifiers (`%1$lld`, `%2$@`) for multi-argument forms.
- Emits a typed accessor on `public enum Strings` — `public static
  var appTitle: String` for argument-free keys, `public static func
  searchHeader(_ arg1: String) -> String` for keys with format
  arguments.
- Annotates the enum with `// SKIP @bridgeMembers` so the SkipFuse
  bridge exposes every accessor to Kotlin.

Every accessor routes through `localized(_ key: String, default value:
String) -> String`, defined alongside the bundle accessor in
`BundleResources.swift`:

```swift
@inline(__always)
func localized(_ key: String, default value: String) -> String {
    Bundle.hackerNewsReaderResources
        .localizedString(forKey: key, value: value, table: nil)
}
```

`Bundle.hackerNewsReaderResources` resolves the catalog on each
platform. On Apple it returns the SwiftPM-synthesised `Bundle.module`.
On Android it constructs `Bundle(path: …/<package>_<module>.resources)`
against Skip's staged resource directory; Skip's auto-generated
`Bundle_Support.swift` intercepts that init shape and routes the
lookup back to the module bundle.

`localizedString(forKey:value:table:)` and `Bundle(path:)` are the
two primitives that *do* bridge through skip-foundation, which is why
the indirection exists.

Android-side localization scaffolding (the `strings.xml` and the
platform-side `tr(...)` helper) is removed; Compose reads
`Strings.appTitle` etc. directly across the SkipFuse bridge.

## Consequences

- One catalog drives both platforms. Adding a string is one entry in
  `Localizable.xcstrings` and one re-run of the generator; the typed
  accessor appears on both sides of the bridge in the same compile.
- `Strings.swift` is generated. Hand-edits get clobbered on the next
  generator run; the file header says so. The catalog is the edit
  point.
- Catalog edits without re-running the generator leave callers
  referencing stale accessors and compile against the previous
  source. The generator is the gate.
- The English source string is the runtime fallback. A missing
  catalog entry returns the source rather than throwing — failures
  are visible to the eye, not at runtime.
- Apple's `String(localized:)` ergonomics — auto-extraction by the
  Xcode tooling, interpolation-as-key — are sacrificed for
  portability. Generated typed accessors recover the call-site
  ergonomics at the cost of one build step.
- `AttributedString` localization is not supported through this path
  and would need a separate plan if it becomes necessary; nothing in
  the current UI requires it.
- The chosen primitives are stable: `localizedString(forKey:value:table:)`
  has been the Foundation lookup since the original API, and Skip's
  `Bundle(path:)` interception is part of the documented Skip
  resource story.
