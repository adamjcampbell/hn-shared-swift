// AppCoreAndroid is intended only for Android builds. The iOS app should
// depend on the `AppCore` product instead. The bodies of AndroidBridge.swift,
// JNIBridge.swift, and SnapshotSink.swift are wrapped in `#if canImport(Android)`
// so this target compiles to an empty module on non-Android hosts — that
// allows `swift build` / `swift test` to validate the package on macOS.
