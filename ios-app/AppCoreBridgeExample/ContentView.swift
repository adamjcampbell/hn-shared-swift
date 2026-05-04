import SwiftUI
import AppCore

struct ContentView: View {
    @State private var appModel = AppModel()

    var body: some View {
        NavigationStack { CitiesContent(state: appModel.state) }
        .environment(\.dispatch, AppEventDispatch(appModel))
    }
}

private struct CitiesContent: View {
    let state: AppState
    @State private var searchText = ""
    @Environment(\.dispatch) private var dispatch

    var body: some View {
        CitiesList(state: state, searchText: searchText)
            .searchable(text: $searchText, prompt: "Filter cities")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: searchText) { _, newValue in
                dispatch(.setSearchQuery(value: newValue))
            }
            .navigationTitle("Cities")
    }
}

private struct CitiesList: View {
    let state: AppState
    let searchText: String
    @Environment(\.isSearching) private var isSearching
    @Environment(\.dispatch) private var dispatch

    var body: some View {
        Group {
            if isSearching {
                searchResults
            } else {
                fullList
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private var searchResults: some View {
        if state.cities.isEmpty && !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List { CityRows(state: state) }
                .listStyle(.plain)
        }
    }

    private var fullList: some View {
        List {
            Section {
                HeaderCard(
                    count: state.globalFavoriteCount,
                    lastRefreshedAt: state.lastRefreshedAt
                )
            }
            Section { CityRows(state: state) }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await dispatch.run(.refresh)
        }
    }
}

private struct CityRows: View {
    let state: AppState
    @Environment(\.dispatch) private var dispatch

    var body: some View {
        ForEach(state.cities) { city in
            CityRow(
                city: city,
                isFavorite: state.favorites.contains(city.id),
                onToggle: {
                    dispatch(.toggleFavorite(id: city.id))
                }
            )
        }
    }
}

private struct HeaderCard: View {
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
    let onToggle: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(city.name).font(.body)
                Text(city.country).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onToggle) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? .pink : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isFavorite)
            }
            .buttonStyle(.plain)
        }
    }
}
