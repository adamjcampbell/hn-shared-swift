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
            .searchable(text: $model.searchQuery, prompt: "Search Hacker News")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .task {
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
                // Overlay (not if/else) keeps StoriesList mounted so scroll position survives a search-cancel cycle.
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
            // `!isLoading` suppresses the stale-empty window during a debounced query change.
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

    // `UIActivityIndicatorView` pauses when List virtualisation detaches its cell; bumping the id remounts it.
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
                // Always mounted so the title doesn't shift width as the spinner fades in/out.
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
