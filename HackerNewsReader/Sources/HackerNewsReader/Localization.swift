import Foundation

/// Resolves the package's localized resource bundle on each platform.
///
/// - On Apple platforms, returns the SwiftPM-synthesized `Bundle.module`.
/// - On Skip Fuse's Android target, the `typealias Bundle = AndroidBundle`
///   hides Foundation's `.module` extension at argument position. We
///   instead construct a `Bundle(path:)` against the resource-folder
///   path Skip stages under the application bundle. Skip's auto-
///   generated `Bundle_Support.swift` intercepts that init shape and
///   routes to the package's module-bundle accessor.
extension Bundle {
    static var hackerNewsReaderResources: Bundle {
        #if os(Android)
        let path = Bundle.main.bundleURL
            .appendingPathComponent("HackerNewsReader_HackerNewsReader.resources")
            .path
        return Bundle(path: path) ?? .main
        #else
        return .module
        #endif
    }
}

/// Looks up `key` in the package's localization catalog and returns
/// the localized value, falling back to `value` when no entry matches
/// the current locale.
///
/// `Bundle.localizedString(forKey:value:table:)` is used directly because
/// `String(localized:bundle:)` and `AttributedString(localized:)` don't
/// resolve cleanly on Skip Fuse's Android Swift target.
///
/// - Parameters:
///   - key: Catalog key to look up in `Localizable.xcstrings`.
///   - value: English source string used as the runtime fallback when
///     no localization matches the current locale.
/// - Returns: The localized string, or `value` if no entry matches.
@inline(__always)
func localized(_ key: String, default value: String) -> String {
    Bundle.hackerNewsReaderResources.localizedString(forKey: key, value: value, table: nil)
}
