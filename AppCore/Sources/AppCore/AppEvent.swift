import Foundation

/// All user-driven mutations flow through this enum.
///
/// On iOS the View calls `appModel.dispatch(.toggleFavorite(id: ...))`
/// directly. On Android the same event is encoded as JSON, sent across
/// JNI as a single string argument to `appcoreDispatch(eventJSON:)`,
/// decoded on the Swift side, and dispatched through the same
/// `AppModel.dispatch` method. Adding a new mutation case here is the
/// only thing required to expose a new action to both platforms.
///
/// **Wire format:** an object with a `type` discriminator plus inline
/// payload fields. Examples:
///
/// ```json
/// {"type":"toggleFavorite","id":"syd"}
/// {"type":"refresh"}
/// ```
///
/// The hand-rolled `Codable` is deliberate. The synthesised representation
/// for an `enum` with associated values is `{"toggleFavorite":{"id":"syd"}}`,
/// which is awkward to mirror in kotlinx.serialization (and historically had
/// asymmetric encode/decode bugs for no-payload cases). The discriminator
/// shape is kotlinx.serialization's default for polymorphic sealed classes,
/// so the Kotlin mirror is `Json { classDiscriminator = "type" }` plus a
/// `@SerialName` per variant.
public enum AppEvent: Sendable, Equatable {
    case toggleFavorite(id: String)
    case refresh
}

extension AppEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case id
    }

    private enum Kind: String, Codable {
        case toggleFavorite
        case refresh
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .toggleFavorite:
            let id = try container.decode(String.self, forKey: .id)
            self = .toggleFavorite(id: id)
        case .refresh:
            self = .refresh
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .toggleFavorite(let id):
            try container.encode(Kind.toggleFavorite, forKey: .type)
            try container.encode(id, forKey: .id)
        case .refresh:
            try container.encode(Kind.refresh, forKey: .type)
        }
    }
}

extension AppEvent {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public func toJSON() -> String {
        guard let data = try? Self.encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let event = try? Self.decoder.decode(AppEvent.self, from: data) else {
            return nil
        }
        self = event
    }
}
