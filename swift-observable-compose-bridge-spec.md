# Cross-platform `@Observable` ↔ Compose Bridge — Implementation Spec

**Status:** Implementation-ready
**Target audience:** An engineer (or coding agent) implementing this end-to-end
**Goal:** A minimal, runnable example app demonstrating a single Swift `@Observable` model shared between an iOS SwiftUI app and an Android Jetpack Compose app, **without Skip**, on the official Swift Android SDK.

---

## 1. What this spec produces

A single Git repository containing:

1. A SwiftPM package (`AppCore`) with two targets — a cross-platform Swift core (`AppCore`) and an Android-only bridge layer (`AppCoreAndroid`).
2. An iOS SwiftUI app target that depends on the `AppCore` product.
3. An Android app module (Gradle) that builds `AppCoreAndroid` (and transitively `AppCore`) as `.so` libraries via the Swift Android SDK, and consumes them through a generated JNI surface (`swift-java jextract --mode=jni`).
4. A small Kotlin holder that adapts the JNI surface into a Compose-friendly state-holder.

The user-visible behaviour on both platforms:

- A list of cities, each with a heart icon.
- Tapping the heart toggles "favorite" status — the heart fills/empties, and the favorited cities sort to the top.
- A header showing two values: a "worldwide favorites" count (a fake stat that randomises on refresh) and a "last refreshed" timestamp.
- Pull-to-refresh on either platform triggers a one-second simulated network call, after which both header values update.

The architectural significance: every piece of logic — the city list, the favorites set, the sort order, the toggle behaviour, the refresh behaviour — lives in a single Swift type. Both UIs are thin renderers.

---

## 2. Top-level design decisions and the reasoning behind them

This section is here so future maintainers don't have to reverse-engineer why things are the way they are. Every decision below has at least one alternative that looked plausible and was rejected for a specific reason.

### 2.1 Why a single `@Observable` class instead of a value-type model

`@Observable` is the official observation framework in Swift since iOS 17 ([SE-0395](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0395-observability.md)). On the iOS side this gives us automatic SwiftUI invalidation with zero boilerplate. On the Android side we have to do work either way; `@Observable` lets us reuse SE-0475's `Observations` async sequence (see §2.4) instead of writing our own change-tracking primitive.

A value-type model would require us to expose change events explicitly. Possible, but more code in the core, less reuse on iOS, and `Observations` doesn't apply to value types.

### 2.2 Why two SwiftPM targets in one package

The cross-platform model has different runtime requirements from the Android-side bridge:

- The model uses only `@Observable`, which is iOS 17+ / macOS 14+. We want the iOS app's deployment target as low as practical.
- The bridge uses `Observations` (Swift 6.2 / iOS 26+ / macOS 26+ on Apple platforms — see §2.4). The iOS app never touches the bridge, so this gating is irrelevant for iOS deployment.

Splitting into two targets makes the asymmetry compile-enforced rather than discipline-enforced:

- `AppCore` is consumed by iOS (deployment target iOS 17) and is also a dependency of `AppCoreAndroid`.
- `AppCoreAndroid` is consumed only when building for Android, where the Swift runtime ships in the APK and OS gating doesn't apply.

A two-package layout (separate `Package.swift` files) was rejected because two repositories means two `Package.resolved` files, two SwiftPM resolution graphs, and worse contributor ergonomics. A single package with two targets gives the same isolation with one `swift build`.

Both targets use **identical Swift settings** (`swiftLanguageMode(.v6)` plus the upcoming-feature flags below). The split is about *what's available at runtime on a given OS*, not about *what concurrency rules apply*. Reviewers shouldn't have to context-switch between targets when reading the code.

### 2.3 Why `NonisolatedNonsendingByDefault` (SE-0461) is enabled

Without it, an unannotated async function is implicitly `@concurrent`, meaning it hops to a generic executor and the caller has to do `Sendable` checking on every parameter. With it, an unannotated async function runs on the caller's actor — so `appState.refresh()` called from a SwiftUI view runs on `MainActor`, called from an actor on the Android bridge runs on that actor's executor. The model carries no isolation annotations and adapts to its caller. This is exactly the property we want for cross-platform code.

References:

- [SE-0461: Run nonisolated async functions on the caller's actor by default](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)
- Donny Wals, [Should you opt-in to Swift 6.2's Main Actor isolation?](https://www.donnywals.com/should-you-opt-in-to-swift-6-2s-main-actor-isolation/)

### 2.4 Why `Observations` (SE-0475) instead of a manual `withObservationTracking` re-arming loop

`Observations` is an `AsyncSequence<T, Never>` that emits a new element whenever any `@Observable` property accessed inside its closure changes. It handles three things we'd otherwise hand-roll:

1. **Re-arming.** A naive `withObservationTracking` callback fires once and is done; you have to re-install it after every fire. `Observations` does this internally.
2. **Transactional batching.** Multiple synchronous mutations (e.g., setting `cities` and `favorites` in the same method body) coalesce into a single emission. Quoting the proposal: "starting transactions at the first willSet and then emitting a value upon that transaction end at the first point of consistency by interoperating with Swift Concurrency."
3. **Cancellation.** Standard `Task` cancellation cancels the iteration. No `stopped` flag, no race on shutdown.

The cost: `Observations` ships with the Swift 6.2 runtime, which on Apple platforms means iOS 26+ / macOS 26+ — but only because Apple ships the Swift standard library *as part of the OS*. On Android the Swift runtime ships *with the app*, so Swift Android SDK 6.3.1 includes `Observations` regardless of the host Android version.

We use `Observations` only in `AppCoreAndroid`. The iOS app uses SwiftUI's built-in observation, which is iOS 17+. So `Observations`'s OS gating costs us nothing.

If `Observations` proves unavailable or buggy on the chosen Swift Android SDK build, §13 documents a drop-in fallback using `withObservationTracking` and `AsyncStream`.

References:

- [SE-0475: Transactional Observation of Values](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0475-observed.md)
- [Apple — `Observations`](https://developer.apple.com/documentation/observation/observations)
- Apple, [Swift 6.2 release notes](https://www.swift.org/blog/swift-6.2-released/)

### 2.5 Why an actor wraps `AppState` on the Android side, and not on iOS

This is the design choice most likely to provoke "isn't this double handling?" — so the reasoning is worth stating explicitly.

The constraint: `AppState` is a non-`Sendable`, non-isolated reference type. Multiple things on the Android side need to touch it:

- JNI mutation entry points (called synchronously from JVM threads we don't fully control)
- The `Observations` task's tracking closure (reads `cities`, `favorites`, etc. to register dependencies)
- The `Observations` consumer loop (delivers snapshots to the JNI sink)

Under Swift 6 region isolation ([SE-0414](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md)), a non-`Sendable` reference can only be in *one* concurrency region. If we let the JNI entry points and the `Observations` task hold the same `AppState` reference without coordination, the compiler (correctly) rejects it as a region-isolation violation.

To fix this we need a single isolation domain that owns `AppState`. Options:

- **Wrap in an `actor`.** Clean, type-system-enforced, no runtime tricks.
- **Wrap in a `Mutex<AppState>`.** Works in theory but locks plus `@Observable` plus Swift 6 strict concurrency is friction-heavy and the `Observations` closure would need to acquire the lock too.
- **Make `AppState` itself an actor.** Doesn't compose with `@Observable` (the macro requires a class, not an actor; observation-tracking is synchronous).
- **Trust the Kotlin holder to serialise calls onto a single thread.** Works in practice but can't be enforced by Swift's type system; relies on a contract the Swift compiler can't verify.

We pick the actor wrap. The actor (`AndroidBridge`) holds `AppState`, owns the `Observations` task, and exposes thin methods that each forward to the corresponding `AppState` method. JNI entry points spawn `Task { await bridge.foo() }`.

This *does* mean JNI mutations are async on the inside — the JNI call returns to Kotlin before the mutation has taken effect on the Swift side. The mutation's effect is visible only when the next snapshot reaches Kotlin via the sink. For a UI app this is actually fine: there's a small delay between user input and visual response, identical to how a real network-backed app would behave. We document this in §9.

iOS doesn't need any of this. SwiftUI views are `@MainActor`, view bodies read `appState.cities` directly on `MainActor`, and `@Observable`'s built-in observation-tracking handles invalidation. There's only one isolation domain (MainActor) and it's the same one the views use.

So the asymmetry isn't accidental: iOS gets a single-isolation-domain story for free; Android needs an actor to construct one. The "double handling" of forwarding methods on `AndroidBridge` *is* the isolation mechanism.

References:

- [SE-0414: Region-based isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md)
- [SE-0306: Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)
- Point-Free [Isolation: Actor Enqueuing](https://www.pointfree.co/episodes/ep362-isolation-actor-enqueuing) and [Isolation: Actor Reentrancy](https://www.pointfree.co/episodes/ep363-isolation-actor-reentrancy) — for the deeper background on actor semantics

### 2.6 Why JSON at the JNI boundary

The snapshot crosses from Swift to Kotlin once per change. Two encoding options:

- **Typed bridging via `swift-java jextract --mode=jni`.** Currently solid for primitives, primitive arrays, and strings; struct support is "under research" per the [GSoC 2025 announcement](https://forums.swift.org/t/gsoc-2025-new-jni-mode-added-to-swift-java-jextract-tool/81858). Our `Snapshot` contains `[City]` and `Set<String>` — the array of nested structs is on the wrong side of the maturity line.
- **JSON via `Codable` on the Swift side, parsed on the Kotlin side.** Universally works, costs ~100µs per snapshot for our payload size (single-digit cities), no exotic dependencies.

JSON wins on conservatism. The boundary is one function call (`encode(snapshot) -> String`) and one parse on the Kotlin side. Replacing it with typed bridging when `swift-java` matures is a localised change — neither `AppState` nor any consumer needs to know.

### 2.7 Why no `@unchecked Sendable` anywhere

Earlier drafts had a `ChangePump` class with `@unchecked Sendable` because the manual re-arming pattern needed mutable state shared across closures and the compiler couldn't prove safety. With `Observations` plus the `AndroidBridge` actor, every shared-mutable concern is either inside the actor (auto-`Sendable`) or in a `Sendable` value type. There's nothing to mark `@unchecked`.

This is a hard acceptance criterion (§10): `git grep` for `@unchecked` and `nonisolated(unsafe)` in `AppCore/Sources/` returns nothing.

---

## 3. Toolchain and platform requirements

| Component | Version |
|---|---|
| Swift toolchain (host) | 6.3.1 or later |
| Swift Android SDK | 6.3.1 release artefact bundle |
| Android NDK | 27d or later (per Swift Android SDK requirements) |
| Xcode | 26.0 or later (for `Observations` to be available if iOS app ever consumed it; not strictly required since iOS app uses only `AppCore`) |
| iOS deployment target | iOS 17 |
| Android `minSdk` | 28 (matches `aarch64-unknown-linux-android28` triple) |
| Android `targetSdk` | latest (35 at time of writing) |
| JDK | 17+ for the Android Gradle build |

Both SwiftPM targets share the same Swift settings:

- `swiftLanguageMode(.v6)`
- `enableUpcomingFeature("NonisolatedNonsendingByDefault")` — SE-0461
- `enableUpcomingFeature("InferIsolatedConformances")` — SE-0470
- `enableExperimentalFeature("StrictConcurrency")` — sanity

The Android target inherits these via SwiftPM's per-target settings; nothing in the per-target `swiftSettings` differs from the core target. The split exists because of *what's available at runtime on each OS* (JNI symbols, `Observations`'s OS gating on Apple) — not because of *different concurrency rules*.

`Observations` requires Swift 6.2+ runtime. Both targets compile with Swift 6.3.1, but only `AppCoreAndroid` actually imports the `Observations` symbol. `AppCore` doesn't, so it remains consumable on iOS 17 deployment targets.

References:

- [Getting Started with the Swift SDK for Android](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)
- [Swift Android Workgroup](https://www.swift.org/android-workgroup/)
- [Swift 6.3 release notes (InfoQ)](https://www.infoq.com/news/2026/04/swift-6-3-android-c-interop/)

---

## 4. Repository layout

```
swift-compose-bridge-example/
├── AppCore/                              # SwiftPM package
│   ├── Package.swift
│   └── Sources/
│       ├── AppCore/                      # Cross-platform target
│       │   ├── AppState.swift
│       │   ├── City.swift
│       │   └── Snapshot.swift
│       └── AppCoreAndroid/               # Android-only target
│           ├── Platform.swift            # #error guard
│           ├── SnapshotSink.swift
│           ├── AndroidBridge.swift
│           └── JNIBridge.swift           # @_cdecl entry points
├── ios-app/
│   ├── AppCoreBridgeExample.xcodeproj
│   └── AppCoreBridgeExample/
│       ├── AppCoreBridgeExampleApp.swift
│       └── ContentView.swift
└── android-app/
    ├── settings.gradle.kts
    ├── core-jni/                         # Module that builds Swift + jextracts
    │   ├── build.gradle.kts
    │   └── src/main/java/com/example/appcore/native/
    │       └── AppCoreNative.java        # Generated by jextract
    └── app/                              # The Android app module
        ├── build.gradle.kts
        └── src/main/java/com/example/appcore/
            ├── ui/
            │   └── MainActivity.kt
            ├── ui/CityScreen.kt
            └── state/
                └── AppStateHolder.kt
```

---

## 5. The Swift code

### 5.1 `AppCore/Sources/AppCore/City.swift`

```swift
import Foundation

public struct City: Sendable, Identifiable, Codable, Equatable {
    public let id: String
    public let name: String
    public let country: String

    public init(id: String, name: String, country: String) {
        self.id = id
        self.name = name
        self.country = country
    }
}

extension Array where Element == City {
    static let demoData: [City] = [
        City(id: "syd", name: "Sydney", country: "Australia"),
        City(id: "mel", name: "Melbourne", country: "Australia"),
        City(id: "tyo", name: "Tokyo", country: "Japan"),
        City(id: "nyc", name: "New York", country: "USA"),
        City(id: "lon", name: "London", country: "UK"),
        City(id: "par", name: "Paris", country: "France"),
    ]
}
```

### 5.2 `AppCore/Sources/AppCore/AppState.swift`

```swift
import Foundation
import Observation

/// The single source of truth for the example app.
///
/// This type is deliberately platform-agnostic. It carries no isolation
/// annotations and no `Sendable` conformance — its isolation is determined
/// by where it is used:
///
/// - On iOS, SwiftUI views are `@MainActor`, so reads and mutations from a
///   view body happen on `MainActor`.
/// - On Android, an `AndroidBridge` actor in `AppCoreAndroid` owns an
///   instance of this type and serialises all access through its executor.
///
/// Async methods declared here run on the caller's actor by default
/// (SE-0461 / `NonisolatedNonsendingByDefault`), so they don't introduce
/// any cross-actor hops.
@Observable
public final class AppState {
    public private(set) var cities: [City] = .demoData
    public private(set) var favorites: Set<String> = []
    public private(set) var globalFavoriteCount: Int = 0
    public private(set) var lastRefreshedAt: Date? = nil

    public init() {}

    /// Toggle whether `id` is in the favorites set, then re-sort `cities`
    /// so favorites bubble to the top.
    ///
    /// Both mutations happen synchronously and are batched into a single
    /// `Observations` transaction — see SE-0475 §"Transactional semantics".
    public func toggleFavorite(_ id: String) {
        if favorites.contains(id) {
            favorites.remove(id)
        } else {
            favorites.insert(id)
        }
        cities.sort { lhs, rhs in
            let lhsFav = favorites.contains(lhs.id)
            let rhsFav = favorites.contains(rhs.id)
            if lhsFav != rhsFav { return lhsFav && !rhsFav }
            return lhs.name < rhs.name
        }
    }

    /// Simulate a network refresh. Sleeps for ~1s then mutates two
    /// observable properties whose changes are visible in the UI as a
    /// running counter and a timestamp.
    ///
    /// Because of `NonisolatedNonsendingByDefault` (SE-0461), this method
    /// runs on the caller's actor. The `await` suspends the actor's queue,
    /// but resumes back on the same actor — so the mutations after the
    /// sleep are still on the caller's isolation domain. There is no
    /// cross-actor data race risk.
    public func refresh() async {
        try? await Task.sleep(for: .seconds(1))
        globalFavoriteCount = Int.random(in: 100...10_000)
        lastRefreshedAt = .now
    }
}
```

### 5.3 `AppCore/Sources/AppCore/Snapshot.swift`

```swift
import Foundation

/// A `Sendable` value-type snapshot of `AppState`.
///
/// Used as the unit of state delivery from Swift to Kotlin. Values are
/// JSON-encoded at the JNI boundary; see §2.6.
public struct Snapshot: Sendable, Codable, Equatable {
    public let cities: [City]
    public let favorites: Set<String>
    public let globalFavoriteCount: Int
    public let lastRefreshedAt: Date?

    public init(from state: AppState) {
        self.cities = state.cities
        self.favorites = state.favorites
        self.globalFavoriteCount = state.globalFavoriteCount
        self.lastRefreshedAt = state.lastRefreshedAt
    }
}
```

### 5.4 `AppCore/Sources/AppCoreAndroid/Platform.swift`

```swift
#if !canImport(Android)
#error("AppCoreAndroid is intended only for Android builds. The iOS app should depend on the AppCore product instead.")
#endif
```

This target is excluded from iOS builds by the iOS app depending on the `AppCore` product (not `AppCoreAndroid`). The `#error` is belt-and-braces in case anyone misconfigures.

### 5.5 `AppCore/Sources/AppCoreAndroid/SnapshotSink.swift`

```swift
import Foundation

/// The Swift-side protocol implemented by the JNI callback bridge.
///
/// Exists so `AndroidBridge` doesn't import any JNI symbols directly —
/// the JNI implementation conforms to this and is injected at construction.
public protocol SnapshotSink: AnyObject, Sendable {
    func deliver(snapshotJSON: String)
}
```

`AnyObject` because the JNI implementation holds JNI handles that need a stable identity. `Sendable` because the sink is captured by the `AndroidBridge` actor and called from the actor's executor.

### 5.6 `AppCore/Sources/AppCoreAndroid/AndroidBridge.swift`

```swift
import Foundation
import Observation
import AppCore

/// The Android-side coordinator. Owns an `AppState` and an `Observations`
/// task; mediates between sync JNI entry points and async observation.
///
/// **Why this is an actor:** see spec §2.5. In short — `AppState` is a
/// non-`Sendable` reference shared between (a) JNI mutation entry points
/// running on JVM threads and (b) the `Observations` task. They must be
/// in the same isolation domain. The actor *is* that isolation domain.
///
/// **Why methods forward to `state`:** the methods on `AppState` are sync
/// and non-isolated; calling them from the actor automatically runs them
/// on the actor's executor (because the actor holds the only reference to
/// the state). This isn't double-handling — it's how the actor's isolation
/// reaches the methods.
public actor AndroidBridge {
    private let state = AppState()
    private let sink: any SnapshotSink
    private var observationTask: Task<Void, Never>?

    public init(sink: any SnapshotSink) {
        self.sink = sink
    }

    /// Begin observing. The caller (the JNI `create` entry point) calls
    /// this once after construction.
    public func start() {
        // The Task body inherits this actor's isolation (Task.init is
        // marked @_inheritActorContext when the surrounding context is
        // actor-isolated — see SE-0420 / SE-0431).
        //
        // The Observations closure also picks up this actor as its
        // isolation via the #isolation default parameter on
        // Observations.init (SE-0475). So `state.cities` etc. are read
        // synchronously on the actor's executor — no data race.
        observationTask = Task { [self] in
            let observations = Observations { Snapshot(from: self.state) }
            for await snapshot in observations {
                let json = Self.encode(snapshot)
                self.sink.deliver(snapshotJSON: json)
            }
        }
    }

    public func toggleFavorite(_ id: String) {
        state.toggleFavorite(id)
    }

    public func refresh() async {
        await state.refresh()
    }

    public func close() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Encoding

    private static func encode(_ snapshot: Snapshot) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
```

### 5.7 `AppCore/Sources/AppCoreAndroid/JNIBridge.swift`

**Note: this file is a sketch.** The `@_cdecl` entry-point shapes and the fire-and-forget-via-`Task` pattern are the architectural commitments. The JNI helper details — `NewGlobalRef`, `GetStringUTFChars`, env attachment, exception handling, ref cleanup in `deinit` — should be implemented using [`swift-java-jni-core`](https://github.com/swiftlang/swift-java-jni-core), whose APIs may differ in detail from what's shown below. Treat the code as a guide to structure, not as drop-in copy-paste.

```swift
import Foundation
import AppCore

// MARK: - Handle management
//
// JNI gives us back an opaque Int64 to pass around. We use it to round-trip
// a strong reference to a `Holder` that owns the `AndroidBridge`.

private final class Holder {
    let bridge: AndroidBridge
    init(bridge: AndroidBridge) { self.bridge = bridge }
}

private func retain(_ holder: Holder) -> Int64 {
    let unmanaged = Unmanaged.passRetained(holder)
    return Int64(bitPattern: UInt64(UInt(bitPattern: unmanaged.toOpaque())))
}

private func borrow(_ handle: Int64) -> Holder {
    let raw = UnsafeRawPointer(bitPattern: UInt(UInt64(bitPattern: handle)))!
    return Unmanaged<Holder>.fromOpaque(raw).takeUnretainedValue()
}

private func release(_ handle: Int64) {
    let raw = UnsafeRawPointer(bitPattern: UInt(UInt64(bitPattern: handle)))!
    Unmanaged<Holder>.fromOpaque(raw).release()
}

// MARK: - JNI sink implementation
//
// Receives snapshots from `AndroidBridge` and forwards them via JNI to a
// Kotlin object the caller registered. Implemented here in Swift, not
// generated by jextract, because it crosses Swift→Java rather than the
// usual Java→Swift direction.

private final class JNICallbackSink: SnapshotSink {
    // Held by the AndroidBridge actor (Sendable). We don't own any JNI
    // env pointers here — we look them up from the JVM each delivery, since
    // the env is thread-bound and the actor's executor thread is not fixed.
    private let globalRef: jobject
    private let methodID: jmethodID

    init(globalRef: jobject, methodID: jmethodID) {
        self.globalRef = globalRef
        self.methodID = methodID
    }

    deinit {
        // Release the global ref. Look up env via JavaVirtualMachine.shared().
        // Implementation detail; see swift-java-jni-core for the exact API.
    }

    func deliver(snapshotJSON: String) {
        // Attach to current thread, lookup env, call the Kotlin method
        // with the JSON string. Details delegated to swift-java-jni-core.
    }
}

// MARK: - JNI entry points
//
// These are sync `@_cdecl` functions called by the JVM. They cannot block
// on the actor (we don't want to deadlock the JVM thread), so mutations
// fire-and-forget via a Task.
//
// The mutation's effect becomes visible to Kotlin only when the next
// snapshot arrives via the SnapshotSink — see §9 for the threading
// contract.

@_cdecl("Java_com_example_appcore_native_AppCoreNative_create")
public func appcore_create(
    env: UnsafeMutablePointer<JNIEnv>,
    clazz: jclass,
    sinkObj: jobject,
    sinkMethodID: jmethodID
) -> Int64 {
    // Promote the local sink ref to a global ref so we can call it from
    // any thread (specifically, the actor's executor thread, which we
    // don't control).
    let globalRef = env.pointee.pointee.NewGlobalRef(env, sinkObj)!
    let sink = JNICallbackSink(globalRef: globalRef, methodID: sinkMethodID)

    let bridge = AndroidBridge(sink: sink)
    let holder = Holder(bridge: bridge)

    // Kick off the observation loop. start() is async on the actor; we
    // spawn an unstructured Task and let it run.
    Task { await bridge.start() }

    return retain(holder)
}

@_cdecl("Java_com_example_appcore_native_AppCoreNative_destroy")
public func appcore_destroy(
    env: UnsafeMutablePointer<JNIEnv>,
    clazz: jclass,
    handle: Int64
) {
    let holder = borrow(handle)
    Task { await holder.bridge.close() }
    release(handle)
}

@_cdecl("Java_com_example_appcore_native_AppCoreNative_toggleFavorite")
public func appcore_toggleFavorite(
    env: UnsafeMutablePointer<JNIEnv>,
    clazz: jclass,
    handle: Int64,
    idStr: jstring
) {
    let holder = borrow(handle)
    let id = swiftString(from: idStr, env: env)
    Task { await holder.bridge.toggleFavorite(id) }
}

@_cdecl("Java_com_example_appcore_native_AppCoreNative_refresh")
public func appcore_refresh(
    env: UnsafeMutablePointer<JNIEnv>,
    clazz: jclass,
    handle: Int64
) {
    let holder = borrow(handle)
    Task { await holder.bridge.refresh() }
}

// String conversion helper — implementation lives in swift-java-jni-core.
private func swiftString(from jstr: jstring, env: UnsafeMutablePointer<JNIEnv>) -> String {
    // Use `GetStringUTFChars` / `ReleaseStringUTFChars` per swift-java-jni-core.
    fatalError("Implement using swift-java-jni-core")
}
```

### 5.8 `AppCore/Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let sharedSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableExperimentalFeature("StrictConcurrency"),
]

let package = Package(
    name: "AppCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "AppCoreAndroid", targets: ["AppCoreAndroid"]),
    ],
    targets: [
        .target(
            name: "AppCore",
            swiftSettings: sharedSettings
        ),
        .target(
            name: "AppCoreAndroid",
            dependencies: ["AppCore"],
            swiftSettings: sharedSettings
        ),
    ]
)
```

`swift-tools-version: 6.0` is the package floor. Building `AppCoreAndroid` requires a 6.3+ toolchain (because `Observations` is in the 6.2+ runtime), but consumers of just the `AppCore` product can use 6.0.

---

## 6. The Android side

### 6.1 `core-jni/build.gradle.kts` — building Swift and generating the JNI surface

Two cross-compilations (one per architecture), then `swift-java jextract` over `AppCoreAndroid`.

**Note: this snippet is illustrative.** The exact task wiring (dependencies between `buildSwift*`, `jextract`, and the standard Android `assemble` lifecycle; whether to use `Exec` tasks or a custom Gradle plugin; how to expose the `.so` outputs to downstream modules) depends on the Android Gradle Plugin version in use and on project conventions. The implementer should expect to refine this — consult the [Swift Android Examples repo](https://github.com/swiftlang/swift-android-examples) (especially `hello-swift-java`) for a working reference. The architectural commitment is: build `AppCoreAndroid` for both Android architectures, then run `jextract --mode=jni --swift-module AppCoreAndroid` over the result.

```kotlin
plugins { id("com.android.library") }

val swiftSdk = "/path/to/swift-android-sdk"  // from `swift sdk list`
val ndk = "/path/to/android-ndk-r27d"

tasks.register<Exec>("buildSwiftAarch64") {
    workingDir = file("../../AppCore")
    commandLine(
        "swift", "build",
        "--swift-sdk", "aarch64-unknown-linux-android28",
        "--product", "AppCoreAndroid",
        "--configuration", "release"
    )
}

tasks.register<Exec>("buildSwiftX86_64") {
    workingDir = file("../../AppCore")
    commandLine(
        "swift", "build",
        "--swift-sdk", "x86_64-unknown-linux-android28",
        "--product", "AppCoreAndroid",
        "--configuration", "release"
    )
}

tasks.register<Exec>("jextractAppCoreAndroid") {
    workingDir = file("../../AppCore")
    commandLine(
        "swift-java", "jextract",
        "--mode=jni",
        "--swift-module", "AppCoreAndroid",
        "--package", "com.example.appcore.native",
        "--output-java", "${projectDir}/src/main/java",
        "--output-swift", "${projectDir}/generated-swift"
    )
}

android {
    namespace = "com.example.appcore.native"
    compileSdk = 35
    defaultConfig { minSdk = 28 }

    sourceSets["main"].apply {
        jniLibs.srcDirs("../../AppCore/.build/aarch64-unknown-linux-android28/release",
                        "../../AppCore/.build/x86_64-unknown-linux-android28/release")
    }
}
```

`jextract --mode=jni` is the consumer-facing tool from [the GSoC 2025 announcement](https://forums.swift.org/t/gsoc-2025-new-jni-mode-added-to-swift-java-jextract-tool/81858). Run it with `--swift-module AppCoreAndroid` so it picks up the JNI surface (the `@_cdecl` functions in `JNIBridge.swift`), not the cross-platform model.

### 6.2 `app/src/main/java/com/example/appcore/state/AppStateHolder.kt`

```kotlin
package com.example.appcore.state

import androidx.compose.runtime.*
import com.example.appcore.native.AppCoreNative
import kotlinx.coroutines.delay
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class City(val id: String, val name: String, val country: String)

@Serializable
data class Snapshot(
    val cities: List<City>,
    val favorites: Set<String>,
    val globalFavoriteCount: Int,
    val lastRefreshedAt: String? = null
)

/**
 * Compose-friendly state holder for AppState.
 *
 * - `snapshot` is a Compose MutableState. Reading it from a composable
 *   subscribes that composable to recomposition on change.
 * - Mutation methods (`toggleFavorite`, `refresh`) call into JNI, which
 *   is fire-and-forget on the Swift side. The result arrives via the
 *   JNI callback, which calls `onSnapshot` and updates `snapshot`.
 */
class AppStateHolder {
    private val handle: Long
    var snapshot by mutableStateOf<Snapshot?>(null)
        private set
    var isRefreshing by mutableStateOf(false)
        private set

    init {
        handle = AppCoreNative.create(
            sinkObj = this,
            sinkMethodName = "onSnapshot",
            sinkMethodSig = "(Ljava/lang/String;)V"
        )
    }

    /** Called from Swift via JNI on every Observations transaction. */
    @Suppress("unused")  // called by JNI
    fun onSnapshot(json: String) {
        snapshot = Json.decodeFromString<Snapshot>(json)
    }

    fun toggleFavorite(id: String) {
        AppCoreNative.toggleFavorite(handle, id)
    }

    suspend fun refresh() {
        isRefreshing = true
        AppCoreNative.refresh(handle)
        // Spinner UX: hold the spinner ~1.1s to roughly match the Swift
        // sleep duration. The actual snapshot arrives independently via
        // onSnapshot. Decoupling the spinner from the snapshot is simpler
        // than threading "refresh complete" back through JNI.
        delay(1100)
        isRefreshing = false
    }

    fun close() {
        AppCoreNative.destroy(handle)
    }
}

@Composable
fun rememberAppState(): AppStateHolder {
    val holder = remember { AppStateHolder() }
    DisposableEffect(holder) { onDispose { holder.close() } }
    return holder
}
```

### 6.3 `app/src/main/java/com/example/appcore/ui/CityScreen.kt`

```kotlin
package com.example.appcore.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.example.appcore.state.rememberAppState
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CityScreen() {
    val holder = rememberAppState()
    val snapshot = holder.snapshot
    val scope = rememberCoroutineScope()

    PullToRefreshBox(
        isRefreshing = holder.isRefreshing,
        onRefresh = { scope.launch { holder.refresh() } }
    ) {
        Column(Modifier.fillMaxSize()) {
            HeaderCard(
                count = snapshot?.globalFavoriteCount,
                lastRefreshedAt = snapshot?.lastRefreshedAt
            )
            LazyColumn(Modifier.fillMaxSize()) {
                items(snapshot?.cities ?: emptyList()) { city ->
                    CityRow(
                        city = city,
                        isFavorite = snapshot?.favorites?.contains(city.id) == true,
                        onToggle = { holder.toggleFavorite(city.id) }
                    )
                }
            }
        }
    }
}

@Composable
private fun HeaderCard(count: Int?, lastRefreshedAt: String?) {
    Card(Modifier.fillMaxWidth().padding(16.dp)) {
        Column(Modifier.padding(16.dp)) {
            Text(
                text = "Worldwide favorites: ${count?.let { "%,d".format(it) } ?: "—"}",
                style = MaterialTheme.typography.titleMedium
            )
            Text(
                text = "Last refreshed: ${formatTimestamp(lastRefreshedAt)}",
                style = MaterialTheme.typography.bodySmall
            )
        }
    }
}

@Composable
private fun CityRow(city: com.example.appcore.state.City, isFavorite: Boolean, onToggle: () -> Unit) {
    ListItem(
        headlineContent = { Text(city.name) },
        supportingContent = { Text(city.country) },
        trailingContent = {
            IconButton(onClick = onToggle) {
                Icon(
                    imageVector = if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                    contentDescription = if (isFavorite) "Unfavorite" else "Favorite"
                )
            }
        }
    )
}

private fun formatTimestamp(iso8601: String?): String {
    if (iso8601 == null) return "never"
    // Best-effort; production code would use kotlinx-datetime.
    return iso8601.substringAfter("T").substringBeforeLast(".").take(8)
}
```

`PullToRefreshBox` is the Material 3 pull-to-refresh container. It expects a `Boolean` `isRefreshing` and an `onRefresh: () -> Unit` callback.

---

## 7. The iOS app

### 7.1 `ios-app/AppCoreBridgeExample/ContentView.swift`

```swift
import SwiftUI
import AppCore

struct ContentView: View {
    @State private var appState = AppState()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HeaderCard(
                        count: appState.globalFavoriteCount,
                        lastRefreshedAt: appState.lastRefreshedAt
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(appState.cities) { city in
                        CityRow(
                            city: city,
                            isFavorite: appState.favorites.contains(city.id),
                            onToggle: { appState.toggleFavorite(city.id) }
                        )
                    }
                }
            }
            .refreshable { await appState.refresh() }
            .navigationTitle("Cities")
        }
    }
}

private struct HeaderCard: View {
    let count: Int
    let lastRefreshedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Worldwide favorites: \(count.formatted(.number))")
                .font(.headline)
            Text("Last refreshed: \(lastRefreshedAt?.formatted(date: .omitted, time: .standard) ?? "never")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
    }
}

private struct CityRow: View {
    let city: City
    let isFavorite: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(city.name).font(.body)
                Text(city.country).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onToggle) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? .pink : .secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
```

`@State` is the SwiftUI property wrapper that observes `@Observable` types since iOS 17. `.refreshable` is the standard pull-to-refresh modifier; it's `async` and shows the spinner until the closure returns. Calling `await appState.refresh()` directly Just Works because (a) the view is `@MainActor`, (b) `refresh()` runs on the caller's actor under SE-0461, (c) the mutations after the sleep are still on `MainActor`, (d) `@Observable` invalidation triggers a SwiftUI redraw.

No `@Environment`, no view model, no observable wrapper. The shared core *is* the view model.

---

## 8. End-to-end flow

A user taps the heart icon on Sydney on Android:

1. Compose calls `holder.toggleFavorite("syd")`.
2. The holder calls `AppCoreNative.toggleFavorite(handle, "syd")` — a sync JNI call.
3. The Swift `appcore_toggleFavorite` `@_cdecl` function spawns `Task { await bridge.toggleFavorite("syd") }` and returns immediately to Kotlin. The Kotlin call site continues without waiting.
4. The Task runs on `AndroidBridge`'s actor executor. It calls `bridge.toggleFavorite(...)`, which calls `state.toggleFavorite(...)` synchronously on the actor.
5. `state.toggleFavorite` mutates `favorites` and `cities`. Both mutations happen synchronously in the same method body, so SE-0475 batches them into one transaction.
6. The `Observations` task wakes up. The closure runs (on the actor's executor, per `#isolation`), reads the four observed properties, constructs a fresh `Snapshot`.
7. The `for await` loop body runs, encodes the snapshot to JSON, calls `sink.deliver(snapshotJSON:)`.
8. `JNICallbackSink.deliver` attaches to the JVM, looks up `env`, calls `holder.onSnapshot(json)` via JNI.
9. `AppStateHolder.onSnapshot` parses the JSON and assigns to `snapshot`. Compose recomposes any composable that read `holder.snapshot`.
10. `CityScreen` renders Sydney with a filled heart and at the top of the list.

The user-visible delay between step 1 and step 10 is dominated by JNI marshalling and JSON encode/decode — single-digit milliseconds for our payload size.

The pull-to-refresh flow is identical except the entry point is `holder.refresh()`, which is `suspend`, takes ~1100ms (Swift's `Task.sleep` plus the holder's matching `delay`), and produces snapshots with new `globalFavoriteCount` and `lastRefreshedAt` values.

On iOS, the flow is shorter: the SwiftUI button calls `appState.toggleFavorite("syd")` directly. The `@Observable` macro records the property writes; SwiftUI invalidates. No JSON, no JNI, no actor.

---

## 9. Threading contract

In one paragraph:

All Swift-side `AppState` access is mediated by the `AndroidBridge` actor. JNI mutation entry points (`appcore_toggleFavorite`, `appcore_refresh`) are sync and fire-and-forget — they spawn an unstructured Task on the actor and return immediately, so the JVM caller doesn't wait for the Swift mutation to complete. The mutation's effect on the observable model becomes visible to Kotlin only when the next snapshot reaches `AppStateHolder.onSnapshot` via the `SnapshotSink`. There is therefore an asynchronous gap between a JNI call returning and the corresponding UI update; this gap is normally well under 10ms but is by-design unbounded (e.g., for the pull-to-refresh case, ~1.1s).

This is the only contract anyone consuming the Swift code needs to know.

---

## 10. Acceptance criteria

These are testable. Each one passes or fails unambiguously.

1. `swift build --swift-sdk aarch64-unknown-linux-android28` succeeds for the `AppCoreAndroid` product, with zero warnings under `-strict-concurrency=complete`.
2. `swift build` for macOS succeeds for the `AppCore` product on iOS 17 deployment target.
3. `git grep -E '@unchecked|nonisolated\(unsafe\)' AppCore/Sources/` returns nothing.
4. The iOS app, run on iOS 17+, displays the city list. Tapping the heart icon on a city instantly toggles the heart and re-orders the list. Pulling to refresh shows a spinner for ~1s, after which the "Worldwide favorites" number changes and the timestamp updates.
5. The Android app, run on Android 10+, displays the same screen. Tapping the heart triggers the same toggle and re-order, with a perceptible but small (<50ms) delay corresponding to the JNI round-trip plus snapshot encode/decode. Pulling to refresh produces a spinner for ~1.1s, after which the same two header values change.
6. After a system-initiated process death (`adb shell am kill com.example.appcore`) and relaunch via the app switcher: the search input is restored from `rememberSaveable`, and the visible city list is filtered consistently with that input — `CityScreen` replays a one-shot `setSearchQuery` on first composition so AppCore's filter catches up with the rehydrated input. Favorites and refresh count are reset to defaults (AppCore-owned state is intentionally not persisted). Swipe-from-recents also resets the search input. See AGENT.md *No persistence* for the rationale.
7. Running both apps side-by-side and comparing screenshots: the layouts are visibly equivalent (city list, header card, heart icons in the same position).

---

## 11. Test strategy

Unit tests live under `AppCore/Tests/AppCoreTests/`. They run on macOS — there's no Android-specific behavior in `AppCore`.

Suggested tests:

- `AppStateTests.toggleFavorite_addsAndRemoves()` — call twice, assert toggling.
- `AppStateTests.toggleFavorite_resortsList()` — assert favorites are first.
- `AppStateTests.refresh_updatesObservables()` — call `await refresh()`, assert `globalFavoriteCount` and `lastRefreshedAt` changed.
- `AppStateTests.refresh_runsOnCallersActor()` — call from a `@MainActor` test method, assert no thread-hop occurred (verify via `MainActor.assertIsolated()` after the await).

`AndroidBridge` tests are hard to write portably because the JNI sink can't be wired up off-device. We document this and rely on integration testing via the actual Android app.

For the `Observations` integration, a single test:

- `BridgeTests.start_emitsSnapshotOnMutation()` — construct `AndroidBridge` with a mock sink, call `start()`, mutate via `toggleFavorite()`, assert the mock received a snapshot. This requires running on macOS 26+ to have `Observations` available.

---

## 12. What's deliberately out of scope

So no one wonders later:

- ~~**Networking.** `refresh()` simulates with `Task.sleep`.~~
  *(Superseded — see §15.)*
- **Persistence.** State resets on app restart. SwiftData / Room would be a follow-up.
- **Localisation.** All strings are English.
- **Accessibility.** The heart icons have content descriptions but the example doesn't go beyond defaults.
- **Multi-window iOS.** One scene only.
- **Tablet / large-screen Android.** Phone layout only.
- **Skip.** Explicitly out — the whole point is doing this without Skip.
- **Mac Catalyst / macOS app.** Only iOS and Android.
- **Production-grade JNI safety.** The `JNIBridge.swift` code is a sketch; an implementer should use [`swift-java-jni-core`](https://github.com/swiftlang/swift-java-jni-core) for the actual env attachment, ref management, and exception handling.

---

## 13. Fallback: if `Observations` is unavailable on the chosen Swift Android SDK

If for some reason the Swift Android SDK build doesn't include `Observations` (we don't expect this for 6.3.1, but it's worth a documented fallback), the only file that changes is `AndroidBridge.swift`. The rest of the architecture is unaffected.

Replace the `start()` method with a manual re-arming pattern wrapped in an `AsyncStream`:

```swift
public func start() {
    let stream = AsyncStream<Snapshot> { continuation in
        self.fireRecursively(continuation: continuation)
    }

    observationTask = Task { [self] in
        for await snapshot in stream {
            let json = Self.encode(snapshot)
            self.sink.deliver(snapshotJSON: json)
        }
    }
}

private func fireRecursively(continuation: AsyncStream<Snapshot>.Continuation) {
    withObservationTracking {
        continuation.yield(Snapshot(from: self.state))
    } onChange: {
        Task { [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            await self.fireRecursively(continuation: continuation)
        }
    }
}
```

Caveats of this fallback vs. `Observations`:

- **No transactional batching.** Two synchronous mutations to `state` will fire two events. The Kotlin holder gets two `onSnapshot` calls in quick succession; recomposition coalesces them in practice but it's wasted work.
- **More complex shutdown.** The `withObservationTracking` callback is `@Sendable` and can fire during teardown — we have to handle the `nil` self case explicitly.
- **`@unchecked Sendable` may creep back in** depending on how the actor's self is captured by the rearming closure. Worth re-evaluating against the acceptance criteria.

Reference: the [JuniperPhoton article on observation framework patterns](https://juniperphoton.substack.com/p/observation-framework-beyond-the) describes this technique in more detail.

---

## 14. References

Swift Evolution proposals:

- [SE-0306: Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)
- [SE-0395: Observation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0395-observability.md)
- [SE-0414: Region-based isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md)
- [SE-0420: Inheritance of actor isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0420-inheritance-of-actor-isolation.md)
- [SE-0430: `sending` parameter and result values](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md)
- [SE-0431: `@isolated(any)` function types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0431-isolated-any-functions.md)
- [SE-0461: `nonisolated(nonsending)` by default](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)
- [SE-0466: Default actor isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)
- [SE-0475: Transactional Observation of Values](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0475-observed.md)

Toolchain and ecosystem:

- [Swift Android Workgroup](https://www.swift.org/android-workgroup/)
- [Getting Started with the Swift SDK for Android](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)
- [Swift Android Examples (`hello-swift-java`)](https://github.com/swiftlang/swift-android-examples)
- [`swift-java`](https://github.com/swiftlang/swift-java)
- [`swift-java-jni-core`](https://github.com/swiftlang/swift-java-jni-core)
- [GSoC 2025: New JNI mode added to swift-java jextract](https://forums.swift.org/t/gsoc-2025-new-jni-mode-added-to-swift-java-jextract-tool/81858)
- [Swift 6.2 release notes](https://www.swift.org/blog/swift-6.2-released/)
- [Swift 6.3 release notes (InfoQ)](https://www.infoq.com/news/2026/04/swift-6-3-android-c-interop/)

Background reading on actor patterns:

- Point-Free, [Isolation: Actor Enqueuing](https://www.pointfree.co/episodes/ep362-isolation-actor-enqueuing)
- Point-Free, [Isolation: Actor Reentrancy](https://www.pointfree.co/episodes/ep363-isolation-actor-reentrancy)
- Point-Free, [Isolation: Performance](https://www.pointfree.co/episodes/ep364-isolation-performance)
- Matt Massicotte, [Default isolation with Swift 6.2](https://www.massicotte.org/default-isolation-swift-6_2/)
- Matt Massicotte, [SE-0420: Inheritance of actor isolation](https://www.massicotte.org/concurrency-swift-6-se-0420/)
- Donny Wals, [Should you opt-in to Swift 6.2's Main Actor isolation?](https://www.donnywals.com/should-you-opt-in-to-swift-6-2s-main-actor-isolation/)

---

## 15. Addendum: networking (Hacker News reader rewrite)

Spec §12 originally listed "Networking" as out of scope (`refresh()`
slept for one second). The example was rewritten to fetch Hacker News
stories from the Algolia HN search API. This section documents the
shape the addendum settled on; it overrides §12's first bullet.

### 15.1 Domain rename

| Spec § | Was | Is |
|---|---|---|
| §5.1 | `City(id, name, country)` + 6-row demo data | `Story(id, title, author, points, commentCount, url?, createdAt)` |
| §5.2 | `cities` / `favorites` / `globalFavoriteCount` / `lastRefreshedAt` | `stories` / `read` / `searchQuery` / `isLoading` / `lastRefreshedAt` / `loadError` |
| §5.2 events | `toggleFavorite(id:)` / `refresh` / `setSearchQuery(value:)` | `toggleRead(id:)` / `refresh` / `setSearchQuery(value:)` |

`AppEvent`'s wire format is unchanged in shape — only the
`toggleFavorite` discriminator becomes `toggleRead`. No new JNI entry
point.

### 15.2 The HTTP client (`AppCore/Sources/AppCore/HNClient.swift`)

`HNClient` is a `Sendable` struct with two `@Sendable` closure
properties:

```swift
public struct HNClient: Sendable {
    public var frontPage: @Sendable () async throws -> [Story]
    public var search:    @Sendable (String) async throws -> [Story]
}
```

The struct shape *is* the natural mock point — tests inject closures
directly without going through `URLSession` or `URLProtocol`.
Production callers use the no-arg `init()`, which wires the closures
to live HTTP via `URLSession`. There's an internal `init(session:)`
test seam for the URL-construction tests that want to drive the live
pipeline through a `URLProtocol`-stubbed session.

`Sendable` conformance is what enables the cancel-and-replace
pattern in `AppModel`: the unstructured `Task` that issues the HTTP
call captures `[client, clock]` directly with no `self` capture, so
there's no non-Sendable region to send across. `URLSession`,
`JSONDecoder`, and the static `URL` constants are all Sendable
already, so the struct's conformance is real (not `@unchecked`).

The Android build uses Foundation's networking sub-component:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
```

### 15.3 Debounce + cancellation

Debouncing lives **inside `AppModel.dispatch`**. `.setSearchQuery`
cancel-and-replaces a stored
`searchTask: Task<[Story], Error>?`:

```swift
case .setSearchQuery(let value):
    state.searchQuery = value
    await runFetch(debounce: Self.searchDebounce)
```

`runFetch` cancels the prior task, captures `[client, clock]` plus
the local `query` (all Sendable) into a new throwing Task, stores
it, and awaits the result on the caller's actor:

```swift
let task = Task<[Story], Error> { [client, clock] in
    if let debounce {
        try await clock.sleep(for: debounce)
    }
    return query.isEmpty
        ? try await client.frontPage()
        : try await client.search(query)
}
searchTask = task
do {
    let stories = try await task.value
    state.stories = stories
    state.lastRefreshedAt = .now
    state.loadError = nil
    state.isLoading = false
} catch is CancellationError {
    return  // a newer dispatch superseded us
} catch {
    state.loadError = error.localizedDescription
    state.isLoading = false
}
```

Why this works under Swift 6 strict concurrency:

- The Task closure captures only `Sendable` values. There is no
  `self` to send across regions, so SE-0461's "unstructured Task in
  nonisolated function captures non-Sendable self" hole doesn't
  apply.
- State commits happen back in the `dispatch` arm, which is on the
  caller's actor — `MainActor` on iOS, `AndroidBridge` on Android.

Cancellation:

- A new `.setSearchQuery` (or `.refresh`) calls `searchTask?.cancel()`
  before storing its own task. The prior task's `clock.sleep` (or
  the fetch call) throws `CancellationError`; the prior dispatch's
  `try await task.value` re-throws it, the `catch is
  CancellationError` arm returns, and the stale result is never
  committed.
- On Android the JNI dispatch is fire-and-forget, but cancellation
  here doesn't depend on Kotlin propagating anything — it's all
  driven by the Swift-side `Task.cancel()` call inside `runFetch`.

`Clock` injection makes the debounce deterministic in tests:

```swift
public init(
    client: HNClient = HNClient(),
    clock: any Clock<Duration> = ContinuousClock()
)
```

Tests pass a `TestClock` (from `pointfreeco/swift-clocks`) and call
`clock.advance(by: .milliseconds(250))` to release suspended sleepers
atomically. The `setSearchQuery_coalescesRapidKeystrokes` and
`refresh_cancelsPendingDebounce` tests run in <1 ms each.

The `do/catch` around `clock.sleep` is load-bearing — don't
"simplify" to `try? await clock.sleep(...)` and rely on the client's
downstream cancellation throw. `URLSession.data` honors cancellation,
but test-mock closures can't be expected to as faithfully. Bailing
at the sleep boundary is robust regardless of what the client does.

### 15.4 `AppState` snapshot growth

`AppState`'s payload size grows from ~340 B to ~10–30 KB depending on
the front page or search results. The spec's §2.6 reasoning ("JSON is
fast enough at the demo's payload scale") still holds for this size,
but the threshold is no longer a single-digit-cities budget — re-
evaluate if pagination ever lands.
