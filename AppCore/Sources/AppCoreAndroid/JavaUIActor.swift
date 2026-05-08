#if canImport(Android)
import Foundation

/// Global actor that pins all bridge work to Android's main `Looper`.
///
/// The `@JavaUIActor`-isolated namespaces (`Bridge`, `AndroidBinding<T>`,
/// `AndroidSnapshot<S>`, `AndroidCommands<C>`) compose the bridge from
/// small reusable primitives — instead of one big `actor AndroidBridge`,
/// state is split across `@JavaUIActor`-isolated declarations that share
/// a single isolation domain (the Looper-pinned executor below).
///
/// **Why a global actor and not the singleton actor we used before:**
/// - state can live wherever it logically belongs (a `PerProperty<T>`-style
///   binding, a snapshot pump, etc.) instead of as fields on one actor.
/// - new bridge primitives can be free `@JavaUIActor func`s; they don't
///   have to be methods on a singleton.
/// - JNI thunks read directly: `JavaUIActor.assumeIsolated { Bridge.foo() }`
///   replaces `AndroidBridge.shared.assumeIsolated { $0.foo() }`.
///
/// **Why the hand-rolled `assumeIsolated`:** the stdlib's
/// `Actor.assumeIsolated` (instance method) gives the closure
/// *actor-instance* isolation, which the type system distinguishes from
/// `@JavaUIActor` global-actor isolation. Only `MainActor.assumeIsolated`
/// is special-cased in the stdlib to bridge them; for custom global
/// actors we need the `withoutActuallyEscaping` + `unsafeBitCast`
/// pattern below. Verified empirically:
/// `JavaUIActor.shared.assumeIsolated { _ in Bridge.bump() }` errors
/// with "call to global actor 'JavaUIActor'-isolated static method
/// 'bump()' in a synchronous actor-isolated context", whereas the
/// hand-rolled form below compiles cleanly.
///
/// `LooperExecutor.checkIsolated()` is the runtime gate that prevents
/// `assumeIsolated` from trapping on the main Looper. That part
/// transferred unchanged from the AndroidBridge actor's executor
/// adoption — same executor, same JNI plumbing.
///
/// **Android-only.** This file is `#if canImport(Android)`-gated
/// end-to-end. On macOS, the bridge falls through to whatever default
/// executor a global actor would inherit (irrelevant — the Android-only
/// JNI thunks aren't invoked on macOS).
@globalActor
public actor JavaUIActor {
    public static let shared = JavaUIActor()

    /// Held in a `static let` because the actor's `unownedExecutor` is
    /// an unowned reference — if the executor's only owner were an
    /// instance property, it'd dangle after deinit. Confirmed gotcha
    /// from the swift-evolution discussions linked in the project's
    /// `swift-java-jni-global-actor.md` reference doc.
    private static let executor = LooperExecutor.shared

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self.executor.asUnownedSerialExecutor()
    }

    /// Synchronous entry into the global-actor isolation domain.
    ///
    /// Used by JNI thunks (which can't `await`) to call into
    /// `@JavaUIActor`-isolated declarations without per-call Task
    /// allocation. Compose always invokes the thunks from the UI thread,
    /// which *is* the executor's pinned thread, so
    /// `preconditionIsolated` succeeds (via `LooperExecutor.checkIsolated`)
    /// and the body runs synchronously.
    public static func assumeIsolated<T>(
        _ operation: @JavaUIActor () throws -> T,
        file: StaticString = #fileID, line: UInt = #line
    ) rethrows -> T {
        shared.preconditionIsolated(file: file, line: line)
        return try withoutActuallyEscaping(operation) { fn in
            try unsafeBitCast(fn, to: (() throws -> T).self)()
        }
    }
}
#endif
