import SwiftUI
import AppCore

struct RootView: View {
    @State private var appModel = AppModel()

    var body: some View {
        NavigationStack { CitiesScreen(state: appModel.state) }
            .environment(\.dispatch, AppEventDispatch(appModel))
    }
}

private struct CitiesScreen: View {
    let state: AppState
    @State private var searchText = ""
    @Environment(\.dispatch) private var dispatch

    var body: some View {
        CitiesContent(state: state, searchText: searchText)
            .searchable(text: $searchText, prompt: "Filter cities")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: searchText) { _, newValue in
                dispatch(.setSearchQuery(value: newValue))
            }
            .navigationTitle("Cities")
    }
}

private struct CitiesContent: View {
    let state: AppState
    let searchText: String
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        FullCitiesList(
            cities: state.cities,
            favorites: state.favorites,
            count: state.globalFavoriteCount,
            lastRefreshedAt: state.lastRefreshedAt
        )
        .overlay {
            if isSearching {
                SearchResults(
                    cities: state.cities,
                    favorites: state.favorites,
                    searchText: searchText
                )
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }
}

private struct SearchResults: View {
    let cities: [City]
    let favorites: Set<String>
    let searchText: String

    var body: some View {
        List { CityRows(cities: cities, favorites: favorites) }
            .listStyle(.plain)
            .background(.background)
            .overlay {
                if cities.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
    }
}

private struct FullCitiesList: View {
    let cities: [City]
    let favorites: Set<String>
    let count: Int
    let lastRefreshedAt: Date?
    @Environment(\.dispatch) private var dispatch

    var body: some View {
        List {
            Section {
                FavoritesSummary(count: count, lastRefreshedAt: lastRefreshedAt)
            }
            Section { CityRows(cities: cities, favorites: favorites) }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await dispatch.run(.refresh)
        }
    }
}

private struct CityRows: View {
    let cities: [City]
    let favorites: Set<String>

    var body: some View {
        ForEach(cities) { city in
            CityRow(city: city, isFavorite: favorites.contains(city.id))
        }
    }
}

private struct FavoritesSummary: View {
    let count: Int
    let lastRefreshedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Worldwide favorites: \(count.formatted(.number))")
                .font(.headline)
            Text("Last refreshed: \(lastRefreshedAt?.formatted(date: .omitted, time: .standard) ?? "never")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CityRow: View {
    let city: City
    let isFavorite: Bool
    @Environment(\.dispatch) private var dispatch

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(city.name).font(.body)
                Text(city.country).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dispatch(.toggleFavorite(id: city.id))
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? .pink : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isFavorite)
            }
            .buttonStyle(.plain)
        }
    }
}
