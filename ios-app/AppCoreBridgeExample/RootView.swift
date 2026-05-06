import SwiftUI
import AppCore

struct RootView: View {
    @State private var appModel = AppModel()
    @State private var presented: IdentifiedURL?

    var body: some View {
        NavigationStack { StoriesScreen(state: appModel.state) }
            .environment(\.dispatch, AppEventDispatch(appModel))
            .sheet(item: $presented) { item in
                SafariView(url: item.url)
                    .ignoresSafeArea()
            }
            .task {
                // Single long-lived consumer of AppCommand. The sheet
                // binding lives here in the SwiftUI tree; user-driven
                // dismissal sets `presented = nil` without touching
                // AppCore.
                for await command in appModel.commands {
                    switch command {
                    case .presentURL(let urlString):
                        presented = IdentifiedURL(urlString)
                    }
                }
            }
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
        StoriesList(state: state)
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
    let state: AppState
    @Environment(\.dispatch) private var dispatch

    var body: some View {
        List {
            Section {
                HeaderCard(
                    searchQuery: state.searchQuery,
                    storyCount: state.stories.count,
                    unreadCount: state.stories.lazy.filter { !$0.isRead }.count,
                    isLoading: state.isLoading,
                    lastRefreshedAt: state.lastRefreshedAt,
                    loadError: state.loadError
                )
            }
            Section { StoryRows(stories: state.stories) }
        }
        .listStyle(.insetGrouped)
        .refreshable { await dispatch.run(.refresh) }
    }
}

private struct StoryRows: View {
    let stories: [Story]

    var body: some View {
        ForEach(stories) { story in
            StoryRow(story: story)
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
    @Environment(\.dispatch) private var dispatch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if story.url != nil {
                Button {
                    dispatch(.openStory(id: story.id))
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
                dispatch(.toggleRead(id: story.id))
            }
            .tint(.blue)
        }
    }

    private var metaLine: String {
        let host = URL(string: story.url ?? "")?.host ?? "news.ycombinator.com"
        let age = story.createdAt.formatted(.relative(presentation: .numeric))
        return "by \(story.author) · \(story.points) pts · \(story.commentCount) comments · \(host) · \(age)"
    }
}
