import SwiftUI
import AppCore

struct RootView: View {
    @State private var appModel = AppModel()

    var body: some View {
        NavigationStack { StoriesScreen(state: appModel.state) }
            .environment(\.dispatch, AppEventDispatch(appModel))
    }
}

private struct StoriesScreen: View {
    let state: AppState
    @State private var searchText = ""
    @Environment(\.dispatch) private var dispatch

    var body: some View {
        StoriesContent(state: state)
            .searchable(text: $searchText, prompt: "Search Hacker News")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: searchText) { _, newValue in
                // AppCore handles its own debounce inside `.setSearchQuery`
                // — see AppModel.dispatch. iOS just forwards every keystroke.
                dispatch(.setSearchQuery(value: newValue))
            }
            .task {
                // One-shot first-appear fetch.
                await dispatch.run(.refresh)
            }
            .navigationTitle("Hacker News")
    }
}

private struct StoriesContent: View {
    let state: AppState

    var body: some View {
        StoriesList(
            stories: state.stories,
            read: state.read,
            searchQuery: state.searchQuery,
            isLoading: state.isLoading,
            lastRefreshedAt: state.lastRefreshedAt,
            loadError: state.loadError
        )
        .overlay {
            // Empty-results overlay (only meaningful for an active search;
            // an empty front page would be a network failure handled via
            // loadError instead).
            if !state.isLoading
                && state.stories.isEmpty
                && !state.searchQuery.isEmpty {
                EmptyResultsOverlay(query: state.searchQuery)
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }
}

private struct StoriesList: View {
    let stories: [Story]
    let read: Set<String>
    let searchQuery: String
    let isLoading: Bool
    let lastRefreshedAt: Date?
    let loadError: String?
    @Environment(\.dispatch) private var dispatch

    var body: some View {
        List {
            Section {
                HeaderCard(
                    searchQuery: searchQuery,
                    storyCount: stories.count,
                    unreadCount: stories.lazy.filter { !read.contains($0.id) }.count,
                    isLoading: isLoading,
                    lastRefreshedAt: lastRefreshedAt,
                    loadError: loadError
                )
            }
            Section { StoryRows(stories: stories, read: read) }
        }
        .listStyle(.insetGrouped)
        .refreshable { await dispatch.run(.refresh) }
    }
}

private struct StoryRows: View {
    let stories: [Story]
    let read: Set<String>

    var body: some View {
        ForEach(stories) { story in
            StoryRow(story: story, isRead: read.contains(story.id))
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

private struct HeaderCard: View {
    let searchQuery: String
    let storyCount: Int
    let unreadCount: Int
    let isLoading: Bool
    let lastRefreshedAt: Date?
    let loadError: String?

    private var titleText: String {
        searchQuery.isEmpty ? "Front page" : "Search: \(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "“\(searchQuery)”")"
    }

    private var metaText: String {
        let stamp = lastRefreshedAt?.formatted(date: .omitted, time: .standard) ?? "never"
        if storyCount == 0 {
            return "Last refreshed: \(stamp)"
        }
        return "\(unreadCount) unread of \(storyCount) · last refreshed \(stamp)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(titleText).font(.headline)
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
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

private struct StoryRow: View {
    let story: Story
    let isRead: Bool
    @Environment(\.dispatch) private var dispatch
    @State private var presented: IdentifiableURL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let urlString = story.url, let url = URL(string: urlString) {
                Button {
                    dispatch(.markRead(id: story.id))
                    presented = IdentifiableURL(url: url)
                } label: {
                    Text(story.title)
                        .font(.body)
                        .foregroundStyle(isRead ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            } else {
                Text(story.title)
                    .font(.body)
                    .foregroundStyle(isRead ? .secondary : .primary)
            }
            Text(metaLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(
                isRead ? "Mark Unread" : "Mark Read",
                systemImage: isRead ? "circle" : "checkmark.circle.fill"
            ) {
                dispatch(.toggleRead(id: story.id))
            }
            .tint(.blue)
        }
        .sheet(item: $presented) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
    }

    private var metaLine: String {
        let host = URL(string: story.url ?? "")?.host ?? "news.ycombinator.com"
        let age = story.createdAt.formatted(.relative(presentation: .numeric))
        return "by \(story.author) · \(story.points) pts · \(story.commentCount) comments · \(host) · \(age)"
    }
}
