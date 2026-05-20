import SwiftUI
import HackerNewsReader

struct RootView: View {
    let core: Core
    @State private var presented: IdentifiedURL?

    var body: some View {
        NavigationStack { StoriesScreen() }
            .environment(core.model)
            .environment(\.sendMessage, core.sendMessage)
            .sheet(item: $presented) { item in
                SafariView(url: item.url)
                    .ignoresSafeArea()
            }
            .task {
                // Long-lived consumer of Command. The sheet binding
                // lives here in the SwiftUI tree; user-driven dismissal
                // sets `presented = nil` without touching the core.
                for await command in core.commands {
                    switch command {
                    case .presentURL(let urlString):
                        presented = IdentifiedURL(urlString)
                    }
                }
            }
    }
}

private struct StoriesScreen: View {
    @Environment(Model.self) private var model
    @Environment(\.sendMessage) private var sendMessage

    var body: some View {
        @Bindable var model = model
        StoriesContent()
            // Writes flow through Model's synthesized setter; the
            // listener Task inside Engine observes the willSet and
            // fires a debounced fetch.
            .searchable(text: $model.searchQuery, prompt: "Search Hacker News")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .task {
                // One-shot first-appear fetch.
                await sendMessage.run(.refresh)
            }
            .navigationTitle("Hacker News")
    }
}

private struct StoriesContent: View {
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        StoriesList()
            .overlay {
                // While the search field is active, occlude the front-page
                // surface (HeaderCard + full list) with the search
                // surface. Overlay (not if/else swap) keeps StoriesList
                // mounted so scroll position survives a search-cancel
                // cycle — and `model.feedStories` survives untouched
                // because the search fetch writes to its own searchIds.
                if isSearching {
                    SearchResults()
                }
            }
            .scrollDismissesKeyboard(.immediately)
    }
}

private struct SearchResults: View {
    @Environment(Model.self) private var model

    var body: some View {
        List {
            Section {
                SearchHeader(
                    query: model.searchQuery,
                    isLoading: model.searchInitialStatus.isLoading,
                    error: model.searchInitialStatus.error
                )
            }
            Section { StoryRows(stories: model.searchResults) }
            if model.searchLoaded?.hasMore == true {
                Section {
                    LoadMoreRow(status: model.searchLoadMoreStatus)
                }
            }
        }
        .listStyle(.insetGrouped)
        .background(.background)
        .overlay {
            // Empty-search-results overlay. The `!isLoading` guard
            // suppresses the brief window during a debounced query
            // change where searchResults are stale-empty before the
            // new fetch lands.
            if !model.searchInitialStatus.isLoading
                && model.searchResults.isEmpty
                && !model.searchQuery.isEmpty {
                EmptyResultsOverlay(query: model.searchQuery)
            }
        }
    }
}

private struct StoriesList: View {
    @Environment(Model.self) private var model
    @Environment(\.sendMessage) private var sendMessage

    var body: some View {
        List {
            Section {
                FeedHeaderCard(
                    storyCount: model.feedStories.count,
                    unreadCount: model.feedStories.lazy.filter { !$0.isRead }.count,
                    lastRefreshedAt: model.feedLoaded?.loadedAt,
                    loadError: model.feedInitialStatus.error
                )
            }
            Section { StoryRows(stories: model.feedStories) }
            if model.feedLoaded?.hasMore == true {
                Section {
                    LoadMoreRow(status: model.feedLoadMoreStatus)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await sendMessage.run(.refresh) }
    }
}

private struct LoadMoreRow: View {
    let status: LoadStatus
    @Environment(\.sendMessage) private var sendMessage

    // Forces a fresh `ProgressView` instance on every row appearance.
    // SwiftUI's `ProgressView` wraps `UIActivityIndicatorView`, which
    // pauses when its host cell is detached during List virtualisation
    // and isn't re-started when the cell is re-attached — bumping the
    // id replaces the indicator, which restarts its animation.
    @State private var spinId = 0

    var body: some View {
        HStack {
            Text(status.error ?? "Loading more…")
                .foregroundStyle(
                    status.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)
                )
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                let showError = status.error != nil && !status.isLoading

                ProgressView()
                    .id(spinId)
                    .opacity(showError ? 0 : 1)

                Button("Try again") { sendMessage(.loadMore) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .opacity(showError ? 1 : 0)
                    .allowsHitTesting(showError)
            }
        }
        .animation(.default, value: status)
        .onAppear {
            spinId &+= 1
            sendMessage(.loadMore)
        }
    }
}

private struct StoryRows: View {
    let stories: [StoryRow]

    var body: some View {
        ForEach(stories) { story in
            StoryRowView(story: story)
        }
    }
}

private struct EmptyResultsOverlay: View {
    let query: String

    var body: some View {
        ContentUnavailableView.search(text: query)
            .background(.background)
    }
}

private struct FeedHeaderCard: View {
    let storyCount: Int
    let unreadCount: Int
    let lastRefreshedAt: Date?
    let loadError: String?

    private var metaText: String {
        let stamp = lastRefreshedAt?.formatted(date: .omitted, time: .standard) ?? "never"
        if storyCount == 0 {
            return "Last refreshed: \(stamp)"
        }
        return "\(unreadCount) unread of \(storyCount) · last refreshed \(stamp)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Front page").font(.headline)
            Text(metaText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct SearchHeader: View {
    let query: String
    let isLoading: Bool
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Searching for “\(query)”").font(.headline)
                // Always present in the layout so the title doesn't
                // shift width as the spinner appears/disappears on each
                // debounce cycle. Opacity animates the fade in/out.
                ProgressView()
                    .controlSize(.small)
                    .opacity(isLoading ? 1 : 0)
            }
            .animation(.default, value: isLoading)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct StoryRowView: View {
    let story: StoryRow
    @Environment(\.sendMessage) private var sendMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if story.url != nil {
                Button {
                    sendMessage(.openStory(id: story.id))
                } label: {
                    Text(story.title)
                        .font(.body)
                        .foregroundStyle(story.isRead ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            } else {
                Text(story.title)
                    .font(.body)
                    .foregroundStyle(story.isRead ? .secondary : .primary)
            }
            Text(metaLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(
                story.isRead ? "Mark Unread" : "Mark Read",
                systemImage: story.isRead ? "circle" : "checkmark.circle.fill"
            ) {
                sendMessage(.toggleRead(id: story.id))
            }
            .tint(.blue)
        }
    }

    private var metaLine: String {
        let host = URL(string: story.url ?? "")?.host ?? "news.ycombinator.com"
        let age = story.createdAt.formatted(.relative(presentation: .numeric))
        return "by \(story.author) · \(story.score) pts · \(story.commentCount) comments · \(host) · \(age)"
    }
}
