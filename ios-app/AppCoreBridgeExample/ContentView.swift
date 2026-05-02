import SwiftUI
import AppCore

struct ContentView: View {
    @State private var appState = AppState()

    var body: some View {
        let snapshot = appState.snapshot
        NavigationStack {
            List {
                Section {
                    HeaderCard(
                        count: snapshot.globalFavoriteCount,
                        lastRefreshedAt: snapshot.lastRefreshedAt
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(snapshot.cities) { city in
                        CityRow(
                            city: city,
                            isFavorite: snapshot.favorites.contains(city.id),
                            onToggle: { appState.toggleFavorite(city.id) }
                        )
                    }
                }
            }
            .refreshable { await appState.refresh() }
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
