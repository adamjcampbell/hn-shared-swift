import Foundation
import Testing
@testable import AppCore
@testable import AppCoreAndroid

@Suite("AppEvent JSON round-trip")
struct AppEventTests {

    @Test("toggleRead encodes with discriminator and id payload")
    func toggleRead_wireShape() throws {
        let event = AppEvent.toggleRead(id: "39184235")
        let json = JNICoder.encode(event)
        #expect(json.contains("\"type\":\"toggleRead\""))
        #expect(json.contains("\"id\":\"39184235\""))

        let decoded = try #require(JNICoder.decode(AppEvent.self, from: json))
        #expect(decoded == event)
    }

    @Test("openStory encodes with discriminator and id payload")
    func openStory_wireShape() throws {
        let event = AppEvent.openStory(id: "39184235")
        let json = JNICoder.encode(event)
        #expect(json.contains("\"type\":\"openStory\""))
        #expect(json.contains("\"id\":\"39184235\""))

        let decoded = try #require(JNICoder.decode(AppEvent.self, from: json))
        #expect(decoded == event)
    }

    @Test("refresh encodes as bare type discriminator")
    func refresh_wireShape() throws {
        let event = AppEvent.refresh
        let json = JNICoder.encode(event)
        #expect(json.contains("\"type\":\"refresh\""))

        let decoded = try #require(JNICoder.decode(AppEvent.self, from: json))
        #expect(decoded == event)
    }

    @Test("decodes hand-written wire literals")
    func decodes_handWrittenLiterals() throws {
        // These are the literal payloads the Kotlin side sends; if Swift
        // ever stops accepting them the cross-language contract has drifted.
        let toggle = try #require(JNICoder.decode(AppEvent.self, from: #"{"type":"toggleRead","id":"100"}"#))
        #expect(toggle == .toggleRead(id: "100"))

        let open = try #require(JNICoder.decode(AppEvent.self, from: #"{"type":"openStory","id":"100"}"#))
        #expect(open == .openStory(id: "100"))

        let refresh = try #require(JNICoder.decode(AppEvent.self, from: #"{"type":"refresh"}"#))
        #expect(refresh == .refresh)
    }

    @Test("rejects unknown discriminators")
    func rejects_unknownDiscriminator() {
        #expect(JNICoder.decode(AppEvent.self, from: #"{"type":"unknown"}"#) == nil)
        #expect(JNICoder.decode(AppEvent.self, from: #"{}"#) == nil)
        #expect(JNICoder.decode(AppEvent.self, from: "garbage") == nil)
    }
}

@Suite("AppCommand JSON round-trip")
struct AppCommandTests {

    @Test("presentURL encodes with discriminator and value payload")
    func presentURL_wireShape() throws {
        let command = AppCommand.presentURL(value: "https://example.com/a")
        let json = JNICoder.encode(command)
        #expect(json.contains("\"type\":\"presentURL\""))
        #expect(json.contains("\"value\":\"https:\\/\\/example.com\\/a\""))

        let decoded = try #require(JNICoder.decode(AppCommand.self, from: json))
        #expect(decoded == command)
    }

    @Test("decodes hand-written wire literals")
    func decodes_handWrittenLiterals() throws {
        // The literal payload Kotlin's kotlinx-serialization will receive
        // through the JNI CommandSink. If Swift ever stops accepting it,
        // the cross-language contract has drifted.
        let present = try #require(JNICoder.decode(AppCommand.self, from: #"{"type":"presentURL","value":"https://example.com"}"#))
        #expect(present == .presentURL(value: "https://example.com"))
    }

    @Test("rejects unknown discriminators")
    func rejects_unknownDiscriminator() {
        #expect(JNICoder.decode(AppCommand.self, from: #"{"type":"unknown"}"#) == nil)
        #expect(JNICoder.decode(AppCommand.self, from: #"{}"#) == nil)
        #expect(JNICoder.decode(AppCommand.self, from: "garbage") == nil)
    }
}

@Suite("Stories JSON wire shape (appcoreGetStoriesJSON)")
struct StoriesWireTests {

    @Test("stories JSON is a bare array, omits all AppState internals, embeds isRead on each story")
    func storiesJSON_bareArray_omitsInternals_embedsIsRead() async {
        let model = AppModel(
            client: HNClient(
                frontPage: {
                    [
                        HNHit(id: "100", title: "A", author: "x", points: 1, commentCount: 0, url: nil, createdAt: Date(timeIntervalSince1970: 1)),
                        HNHit(id: "101", title: "B", author: "y", points: 2, commentCount: 0, url: nil, createdAt: Date(timeIntervalSince1970: 2)),
                    ]
                },
                search: { _ in [] }
            )
        )
        await model.dispatch(.refresh)
        await model.dispatch(.toggleRead(id: "100"))
        model.state.searchQuery = "rust"

        // `appcoreGetStoriesJSON` encodes stories directly — a bare JSON
        // array that Kotlin decodes as `List<Story>`.
        let json = JNICoder.encode(model.state.stories)

        // Bare array shape — no enclosing `{"stories": ...}` envelope.
        #expect(json.hasPrefix("["))
        // Internal AppState fields never cross the wire.
        #expect(!json.contains("\"hits\""))
        #expect(!json.contains("\"readIds\""))
        // Per-property scalar fields have their own dedicated getters;
        // they must not appear inside the stories array.
        #expect(!json.contains("\"searchQuery\""))
        #expect(!json.contains("\"rust\""))
        #expect(!json.contains("\"isLoading\""))
        #expect(!json.contains("\"lastRefreshedAt\""))
        #expect(!json.contains("\"loadError\""))
        // No underscore-prefixed keys — guards against @Observable macro's
        // backing storage leaking into the wire format.
        #expect(!json.contains("\"_"))
        // isRead is derived from `readIds` and embedded on each Story.
        #expect(json.contains("\"isRead\":true"))
        #expect(json.contains("\"isRead\":false"))
    }
}
