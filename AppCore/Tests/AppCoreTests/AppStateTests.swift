import Testing
@testable import AppCore

@Suite("AppState")
struct AppStateTests {

    @Test("toggleFavorite adds and removes")
    func toggleFavorite_addsAndRemoves() {
        let state = AppState()
        #expect(state.snapshot.favorites.contains("syd") == false)

        state.toggleFavorite("syd")
        #expect(state.snapshot.favorites.contains("syd"))

        state.toggleFavorite("syd")
        #expect(state.snapshot.favorites.contains("syd") == false)
    }

    @Test("toggleFavorite resorts list with favorites first")
    func toggleFavorite_resortsList() {
        let state = AppState()
        // Favourite a city that isn't naturally first alphabetically.
        state.toggleFavorite("tyo")
        #expect(state.snapshot.cities.first?.id == "tyo")

        // Favouriting another bubbles both to the top, sorted by name.
        state.toggleFavorite("par")
        let topTwoIDs = state.snapshot.cities.prefix(2).map(\.id)
        #expect(Set(topTwoIDs) == ["tyo", "par"])
        // "Paris" < "Tokyo" alphabetically, so Paris should be first.
        #expect(state.snapshot.cities[0].id == "par")
        #expect(state.snapshot.cities[1].id == "tyo")
    }

    @Test("refresh updates observable properties")
    func refresh_updatesObservables() async {
        let state = AppState()
        #expect(state.snapshot.globalFavoriteCount == 0)
        #expect(state.snapshot.lastRefreshedAt == nil)

        await state.refresh()

        #expect(state.snapshot.globalFavoriteCount > 0)
        #expect(state.snapshot.lastRefreshedAt != nil)
    }

    @Test("refresh runs on caller's actor")
    @MainActor
    func refresh_runsOnCallersActor() async {
        let state = AppState()
        await state.refresh()
        // SE-0461: NonisolatedNonsendingByDefault means refresh() runs on
        // the caller's actor (MainActor here) and the resumption after the
        // await stays on it. Verify we are still on MainActor.
        MainActor.assertIsolated()
    }
}
