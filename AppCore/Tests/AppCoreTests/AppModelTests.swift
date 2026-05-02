import Testing
@testable import AppCore

@Suite("AppModel")
struct AppModelTests {

    @Test("toggleFavorite adds and removes")
    func toggleFavorite_addsAndRemoves() async {
        let model = AppModel()
        #expect(model.state.favorites.contains("syd") == false)

        await model.dispatch(.toggleFavorite(id: "syd"))
        #expect(model.state.favorites.contains("syd"))

        await model.dispatch(.toggleFavorite(id: "syd"))
        #expect(model.state.favorites.contains("syd") == false)
    }

    @Test("toggleFavorite resorts list with favorites first")
    func toggleFavorite_resortsList() async {
        let model = AppModel()
        // Favourite a city that isn't naturally first alphabetically.
        await model.dispatch(.toggleFavorite(id: "tyo"))
        #expect(model.state.cities.first?.id == "tyo")

        // Favouriting another bubbles both to the top, sorted by name.
        await model.dispatch(.toggleFavorite(id: "par"))
        let topTwoIDs = model.state.cities.prefix(2).map(\.id)
        #expect(Set(topTwoIDs) == ["tyo", "par"])
        // "Paris" < "Tokyo" alphabetically, so Paris should be first.
        #expect(model.state.cities[0].id == "par")
        #expect(model.state.cities[1].id == "tyo")
    }

    @Test("refresh updates observable properties")
    func refresh_updatesObservables() async {
        let model = AppModel()
        #expect(model.state.globalFavoriteCount == 0)
        #expect(model.state.lastRefreshedAt == nil)

        await model.dispatch(.refresh)

        #expect(model.state.globalFavoriteCount > 0)
        #expect(model.state.lastRefreshedAt != nil)
    }

    @Test("refresh runs on caller's actor")
    @MainActor
    func refresh_runsOnCallersActor() async {
        let model = AppModel()
        await model.dispatch(.refresh)
        // SE-0461: NonisolatedNonsendingByDefault means dispatch/refresh
        // run on the caller's actor (MainActor here) and the resumption
        // after the await stays on it. Verify we are still on MainActor.
        MainActor.assertIsolated()
    }
}

@Suite("AppEvent JSON round-trip")
struct AppEventTests {

    @Test("toggleFavorite encodes with discriminator and id payload")
    func toggleFavorite_wireShape() throws {
        let event = AppEvent.toggleFavorite(id: "syd")
        let json = event.toJSON()
        #expect(json.contains("\"type\":\"toggleFavorite\""))
        #expect(json.contains("\"id\":\"syd\""))

        let decoded = try #require(AppEvent(json: json))
        #expect(decoded == event)
    }

    @Test("refresh encodes as bare type discriminator")
    func refresh_wireShape() throws {
        let event = AppEvent.refresh
        let json = event.toJSON()
        #expect(json.contains("\"type\":\"refresh\""))

        let decoded = try #require(AppEvent(json: json))
        #expect(decoded == event)
    }

    @Test("decodes hand-written wire literals")
    func decodes_handWrittenLiterals() throws {
        // These are the literal payloads the Kotlin side sends; if Swift
        // ever stops accepting them the cross-language contract has drifted.
        let toggle = try #require(AppEvent(json: #"{"type":"toggleFavorite","id":"syd"}"#))
        #expect(toggle == .toggleFavorite(id: "syd"))

        let refresh = try #require(AppEvent(json: #"{"type":"refresh"}"#))
        #expect(refresh == .refresh)
    }

    @Test("rejects unknown discriminators")
    func rejects_unknownDiscriminator() {
        #expect(AppEvent(json: #"{"type":"unknown"}"#) == nil)
        #expect(AppEvent(json: #"{}"#) == nil)
        #expect(AppEvent(json: "garbage") == nil)
    }
}
