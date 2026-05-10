# Tuple return for fused observation registration

This document explains why `appcoreObserve*` thunks return Swift tuples
`(Int64, T)` rather than firing a separate `Subscription` callback or
splitting into two thunks. It's an implementation note for the
`SwiftState` / `SwiftBinding` design.

## The problem

A single observation registration needs to deliver two things to Kotlin:
1. The **cancellation token** (an `Int64` that names the registered Task
   in `Bridge.observations`).
2. The **initial value** of the observed property (so `MutableState` has
   something to seed with).

Whichever shape we pick, both pieces have to cross the JNI boundary in
the construction step. The options:

| Shape | Round-trips | Notes |
|---|---|---|
| Two thunks (`appcoreObserveX → token`, `appcoreReadX → value`) | 2 K→S | Forces the binding to read twice on construction |
| One thunk + Kotlin-implemented `Subscription` callback for the token | 1 K→S + 1 inner S→K | Adds a protocol; small allocation per call |
| One thunk that returns the tuple `(Int64, T)` | 1 K→S | What we use today |

## Why tuples bridge cleanly

jextract's JNI mode supports Swift tuples (per
`SupportedFeatures.md` in the swift-java repo: *"Tuples: `(Int, String)`,
`(A, B, C)` ✅ JNI"*).

For `func appcoreObserveIsLoading(callback: some OnChange) -> (Int64, Bool)`,
jextract emits:

```java
public static Tuple2<Long, Boolean> appcoreObserveIsLoading(_T0 callback) {
    long[] result_0$ = new long[1];
    boolean[] result_1$ = new boolean[1];
    AppCoreAndroid.$appcoreObserveIsLoading(callback, result_0$, result_1$);
    return new Tuple2<Long, Boolean>(result_0$[0], result_1$[0]);
}
private static native void $appcoreObserveIsLoading(
    java.lang.Object callback, long[] result_0$, boolean[] result_1$);
```

**Mechanism.** The native call takes one out-param array per tuple slot
(`long[1]`, `boolean[1]`, `String[1]`, `byte[1]` for Optional
discriminator, etc.). The wrapper allocates the arrays, calls the native
method, and assembles them into
`org.swift.swiftkit.core.tuple.Tuple2<…>` from the swiftkit-core JAR we
already depend on for the rest of the bridge.

Tuple2 has public final fields `$0` and `$1`. We add component
extensions on the Kotlin side (in `SwiftState.kt`) so
`val (token, initial) = swiftState.observe(cb)` destructures
naturally.

## Why we picked this over the alternatives

### Two thunks (`appcoreObserveX` + `appcoreReadX` for the initial value)

We tried this first. Issue: every binding pays an extra `appcoreReadX`
call at construction just to fetch the initial value, on top of the
register-and-get-token call. For a binding with N emissions, that's
**N + 3** K→S thunk calls per lifecycle vs **N + 2** for the fused shape.
Doesn't sound like much, but it's a wasted call where the *only* reason
it exists is jextract's tuple-return support being unknown to us at the
time.

### `Subscription` callback for the token

We then tried this — Swift fires `subscription.attached(token:)` inline
inside the observe thunk, returns the value, Kotlin captures the token
in a closure-scoped `var`. Worked, but:

- Adds a `Subscription` protocol (and a `JavaSubscription:
  @unchecked Sendable` line in `JavaInterop.swift`).
- Every observe call site takes two callback arguments (`onChange` and
  `subscription`), each passed as a Kotlin lambda or method reference.
- The `var capturedToken = -1L; … ; token = capturedToken` dance
  in `SwiftBinding.init` is a slight code smell — it's safe (the
  attach is fired synchronously inside observe) but it asks the
  reader to verify that synchronous-firing assumption.
- Inner S→K boundary cross per construction (the attach callback) —
  cheap but real.

### Tuple return (current)

Replaces the `Subscription` protocol with one Swift tuple type and a
Kotlin component-extension pair. Net delta from the Subscription
shape:

- **Removed:** `Subscription.swift` protocol, the `JavaSubscription:
  @unchecked Sendable` line, the `subscription:` parameter on every
  observe thunk, the `var capturedToken` dance in `SwiftBinding`,
  the `Subscription { token -> ... }` construction at every observe
  call site in tests.
- **Added:** `org.swift.swiftkit.core.tuple.Tuple2` import in two
  Kotlin files, two extension operators (`component1`, `component2`
  on `Tuple2`).

Construction call site reads as you'd expect:

```kotlin
val (token, initial) = swiftState.observe(OnChange { state.value = read() })
```

instead of

```kotlin
var capturedToken = -1L
val initial = swiftState.observe(
    OnChange { state.value = read() },
    Subscription { capturedToken = it },
)
val token = capturedToken
```

## Costs

Per binding registration:

- **One `Tuple2` allocation** (a small Java object holding two field
  references).
- **Boxing of primitive tuple slots**. `Tuple2<Long, Boolean>` boxes
  the `long` and `boolean` into `Long` and `Boolean` objects.
  `Boolean.valueOf` is cached for `true`/`false`. `Long.valueOf` caches
  values in `[-128, 127]`; outside that range it allocates. For our
  monotonically-increasing observation tokens we'll quickly miss the
  cache, so each token allocates a `Long` box.
- **Two out-param array allocations** inside the native wrapper
  (`long[1]`, plus one per other slot type).

For 5 bindings created once at app startup, that's ~10 small object
allocations total — completely invisible. For a hypothetical
high-frequency case (a screen with hundreds of observed properties
constructed and disposed rapidly) this would start to show up; in that
regime the Subscription pattern would be slightly cheaper because it
returns native primitives directly.

## What this enables for future work

The same tuple pattern would generalize trivially to:

- Returning `(Int64, T1, T2)` if a future thunk needs to deliver three
  pieces (token + value + something else like a generation counter for
  optimistic concurrency).
- Bridging Swift APIs that naturally return tuples (e.g. result + error
  code, key + value pairs, coordinate pairs). jextract handles up to
  `Tuple21` per the swiftkit-core source.

The destructuring extensions we add for `Tuple2<A, B>` would extend
naturally to `Tuple3`/`Tuple4`/etc.

## Source pointers

- jextract supports tuple returns: see
  `Sources/SwiftJavaDocumentation/Documentation.docc/SupportedFeatures.md`
  in the `swiftlang/swift-java` repo (the supported-features matrix).
- `org.swift.swiftkit.core.tuple.Tuple2` is in
  `SwiftKitCore/src/main/java/org/swift/swiftkit/core/tuple/Tuple2.java`
  in the same repo. Public final `$0`, `$1` fields; `equals`,
  `hashCode`, `toString` provided.
- The destructuring extensions live at the top of
  `android-app/.../state/SwiftState.kt`.
- The fused observe-and-return-tuple is the private `observe<T>` helper
  in `AppCore/Sources/AppCoreAndroid/AppCoreNative.swift`.
