import Foundation
import AppCore

/// JSON codec for values that cross JNI.
///
/// `AppEvent`, `AppCommand`, and `[Story]` cross JNI as JSON strings.
/// The cross-platform model types carry no JSON helpers themselves —
/// they're consumed natively on iOS and only need a wire format on
/// Android. This enum is the single home for that wire format: a cached
/// `JSONEncoder`/`JSONDecoder` plus generic `encode`/`decode` helpers.
///
/// Scalar `AppState` properties (`searchQuery`, `isLoading`,
/// `lastRefreshedAt`, `loadError`) cross JNI as native JNI types
/// via their dedicated `appcore*` getters — not via this encoder.
/// The encoder's `.iso8601` date strategy is retained for consistency.
public enum JNICoder {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    public static func decode<T: Decodable>(_ type: T.Type = T.self, from json: String) -> T? {
        guard let data = json.data(using: .utf8),
              let value = try? decoder.decode(type, from: data) else {
            return nil
        }
        return value
    }
}
