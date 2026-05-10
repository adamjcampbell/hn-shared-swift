#if canImport(Android)
import Foundation
import AppCore

/// Opaque snapshot wrapper for `[Story]` crossing the JNI boundary.
///
/// `appcoreObserveStories` returns `(token, initialPeer)` for the
/// initial snapshot and emits a fresh peer pointer via `LongOnChange`
/// on every subsequent change — each peer is created via
/// `Unmanaged.passRetained(...).toOpaque()`. The Kotlin side reads
/// fields via per-accessor thunks (`appcoreStoryId`, etc.), each of
/// which `takeUnretainedValue()`s the peer back from the raw pointer.
/// Lifetime is bounded by Kotlin: the `SwiftState`'s observe lambda
/// wraps the per-emission walk in `try { ... } finally {
/// appcoreStoriesRelease(peer) }`, so the peer dies as soon as the
/// `List<Story>` is materialised — no Cleaner / AutoCloseable plumbing
/// needed.
///
/// `@unchecked Sendable` because the held `[Story]` is immutable
/// post-init and `Story` is itself `Sendable`.
final class StoriesSnapshotPeer: @unchecked Sendable {
    let stories: [Story]
    init(_ stories: [Story]) { self.stories = stories }
}
#endif
