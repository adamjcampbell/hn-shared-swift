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
                // Synchronous local update; the .task(id:) below drives
                // the debounced network fetch.
                dispatch(.setSearchQuery(value: newValue))
            }
            .task(id: searchText) {
                // Debounce + cancel-and-refire pattern. SwiftUI cancels
                // the prior body when `id` changes, which throws inside
                // any awaiting URLSession data task; AppCore's `runFetch`
                // catches CancellationError and skips the state update.
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled {
                    await dispatch.run(.refresh)
                }
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let urlString = story.url, let url = URL(string: urlString) {
                    Link(story.title, destination: url)
                        .font(.body)
                        .foregroundStyle(isRead ? .secondary : .primary)
                } else {
                    Text(story.title)
                        .font(.body)
                        .foregroundStyle(isRead ? .secondary : .primary)
                }
                Text(metaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                dispatch(.toggleRead(id: story.id))
            } label: {
                Image(systemName: isRead ? "circle.fill" : "circle.dotted")
                    .foregroundStyle(isRead ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRead ? "Mark unread" : "Mark read")
        }
    }

    private var metaLine: String {
        let host = URL(string: story.url ?? "")?.host ?? "news.ycombinator.com"
        let age = story.createdAt.formatted(.relative(presentation: .numeric))
        return "by \(story.author) · \(story.points) pts · \(story.commentCount) comments · \(host) · \(age)"
    }
}
