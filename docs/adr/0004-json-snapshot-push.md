# ADR-0004: JSON-snapshot push from `@Observable` to Compose

## Status

Superseded by [ADR-0007](0007-per-property-typed-jni-thunks.md) on 2026-05-07 (per-property typed JNI thunks replaced the snapshot push), and then by [ADR-0013](0013-skipfuse-bridgemembers.md) on 2026-05-10 (SkipFuse removed the hand-written bridge entirely).

## Context

The shared `@Observable` `AppState` lives in a single Swift instance per process. Compose needs to read individual fields of that state and recompose when they change. The first cut of the bridge needed to answer: *what data crosses the JNI boundary, and in what shape?*

At the time of this decision, the JNI-mode of `swift-java jextract` had solid support for primitives, primitive arrays, and strings, but its support for structs and arrays of structs was listed as "under research" in the GSoC 2025 announcement. The shared state included `[City]` (and later `[Story]`) — arrays of nested structs sitting on the wrong side of that maturity line.

Two encoding strategies were on the table:

1. Bridge each field as its own typed JNI value via `jextract`, accepting that structured collections will not work yet.
2. Encode the whole `AppState` as a single JSON snapshot, push that string across JNI on every change, and parse it on the Kotlin side.

Option 1 would have required a per-field JNI surface for every observable property and could not carry `[Story]` end-to-end. Option 2 traded a single JNI primitive (`String`) for a serialise/deserialise round-trip whose cost is dominated by JSON encoding rather than the JNI call itself.

## Decision

`AppState` carries a `Sendable, Codable Snapshot` value type. The Android bridge owns an `Observations { Snapshot(from: state) }` loop running inside an `AndroidBridge` actor; on every transaction end the loop encodes the snapshot to JSON via `JSONEncoder` and pushes the resulting `String` across JNI through a `SnapshotSink` protocol. Kotlin parses the JSON back into a mirror `Snapshot` data class and updates a `MutableState<Snapshot?>` that Compose reads from.

Byte-identical snapshots are deduplicated on the Swift side before the JNI call, so quiescent observation loops don't generate work.

## Consequences

- All structured data crosses the boundary in one well-understood format. No struggle with jextract's evolving struct support.
- The wire format is human-readable, which makes debugging easy: log the JSON, paste it into a viewer, see what Compose received.
- Every change to any field pays the cost of encoding the whole snapshot — not just the changed bytes. For the cities demo this was ~100µs per snapshot. When the project pivoted to the Hacker News reader the payload grew to ~10–30KB per snapshot (front-page list plus search results), and the JSON encode cost grew proportionally.
- The Kotlin side reads one `MutableState<Snapshot?>` per process. Composables that only depend on `searchQuery` still recompose when `stories` changes, because they share the snapshot cell. Granular reactivity is not available under this approach.
- The "snapshot push" shape implies a coarse-grained latency floor: a change is visible to Compose only after the next full encode/transmit/decode cycle, not when the field itself changed.
- Two-way bindings (e.g. the search field, which Compose writes and Swift reads) require a separate path because the snapshot push is one-way (Swift → Kotlin). The first cut handled this by sending the new search-query value through the existing `Message` enum.

The architectural fork happened at 2026-05-07: rather than continuing to optimise the snapshot encoder, [ADR-0007](0007-per-property-typed-jni-thunks.md) replaced JSON snapshots with per-property typed JNI accessors. The snapshot push lived on briefly for the parts of `AppState` that hadn't been ported, then was deleted entirely as the per-property surface covered all fields.
