import SwiftUI
import AppCore

struct ContentView: View {
    @State private var appModel = AppModel()
    @State private var queryString = ""

    var body: some View {
        let appState = appModel.state
        NavigationStack {
            List {
                Section {
                    HeaderCard(
                        count: appState.globalFavoriteCount,
                        lastRefreshedAt: appState.lastRefreshedAt
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                Section {
                    TextField("Filter cities", text: $queryString)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(appState.cities) { city in
                        CityRow(
                            city: city,
                            isFavorite: appState.favorites.contains(city.id),
                            onToggle: {
                                Task { await appModel.dispatch(.toggleFavorite(id: city.id)) }
                            }
                        )
                    }
                }
            }
            .refreshable { await appModel.dispatch(.refresh) }
            .onChange(of: queryString) { _, newValue in
                Task { await appModel.dispatch(.setSearchQuery(value: newValue)) }
            }
            .navigationTitle("Cities")
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
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
            }
            .buttonStyle(.plain)
        }
    }
}
