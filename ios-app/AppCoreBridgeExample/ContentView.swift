import SwiftUI
import AppCore

struct ContentView: View {
    @State private var appModel = AppModel()
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            CitiesContent(appModel: appModel, searchText: searchText)
                .searchable(text: $searchText, prompt: "Filter cities")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, newValue in
                    Task { await appModel.dispatch(.setSearchQuery(value: newValue)) }
                }
                .navigationTitle("Cities")
        }
    }
}

private struct CitiesContent: View {
    let appModel: AppModel
    let searchText: String
    @Environment(\.isSearching) private var isSearching

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
        if appModel.state.cities.isEmpty && !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List { CityRows(appModel: appModel) }
                .listStyle(.plain)
        }
    }

    private var fullList: some View {
        List {
            Section {
                HeaderCard(
                    count: appModel.state.globalFavoriteCount,
                    lastRefreshedAt: appModel.state.lastRefreshedAt
                )
            }
            Section { CityRows(appModel: appModel) }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await appModel.dispatch(.refresh)
        }
    }
}

private struct CityRows: View {
    let appModel: AppModel

    var body: some View {
        ForEach(appModel.state.cities) { city in
            CityRow(
                city: city,
                isFavorite: appModel.state.favorites.contains(city.id),
                onToggle: {
                    Task { await appModel.dispatch(.toggleFavorite(id: city.id)) }
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
