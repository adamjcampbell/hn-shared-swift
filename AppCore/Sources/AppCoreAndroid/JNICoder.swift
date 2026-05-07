import Foundation
import AppCore

/// JSON codec for values that ride the JNI snapshot pipe.
///
/// The cross-platform `AppCore` model types (`AppEvent`, `AppCommand`,
/// `AppState`) carry no JSON helpers themselves — they're consumed
/// natively on iOS and only need a wire format on Android. This enum
/// is the single home for that wire format: a cached
/// `JSONEncoder`/`JSONDecoder` plus generic `encode`/`decode` helpers.
///
/// The encoder uses `.iso8601` for `Date` so `AppState.lastRefreshedAt`
/// crosses JNI as an ISO8601 string Kotlin's `kotlinx.serialization`
/// can parse.
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
