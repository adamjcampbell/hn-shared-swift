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
                // Long-lived consumer of AppCommand. The sheet binding
                // lives here in the SwiftUI tree; user-driven dismissal
                // sets `presented = nil` without touching AppCore.
                for await command in appModel.commands {
                    switch command {
                    case .presentURL(let urlString):
                        presented = IdentifiedURL(urlString)
                    }
                }
            }
            .task {
                // searchQuery watcher: AppModel iterates
                // `state.searchQueryChanges` (an AsyncStream fed by
                // searchQuery's didSet) and either fires a debounced
                // search or clears search state when the query becomes
                // empty. Cancellation propagates when this `.task` is
                // torn down on view disappear.
                await appModel.runSearchQueryWatcher()
            }
    }
}

private struct StoriesScreen: View {
    @Bindable var state: AppState
    @Environment(\.dispatch) private var dispatch

    var body: some View {
        StoriesContent(state: state)
            // Direct two-way binding into the @Observable state. Writes
            // through `$state.searchQuery` go through `AppState`'s
            // synthesized setter; `RootView`'s watcher Task observes the
            // willSet and fires a debounced fetch. No closure-shim
            // Binding(get:set:) — that pattern destroys the Hashable
            // identity SwiftUI's animation/transaction tracking relies
            // on (Point-Free #289).
            .searchable(text: $state.searchQuery, prompt: "Search Hacker News")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .task {
                // One-shot first-appear fetch.
                await dispatch.run(.refresh)
            }
            .navigationTitle("Hacker News")
    }
}

private struct StoriesContent: View {
    let state: AppState
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        StoriesList(state: state)
            .overlay {
                // While the search field is active, occlude the front-page
                // surface (HeaderCard + full list) with the search
                // surface. Overlay (not if/else swap) keeps StoriesList
                // mounted so scroll position survives a search-cancel
                // cycle — and `state.feedStories` survives untouched
                // because the search fetch writes to its own searchIds.
                if isSearching {
                    SearchResults(state: state)
                }
            }
            .scrollDismissesKeyboard(.immediately)
    }
}

private struct SearchResults: View {
    let state: AppState

    var body: some View {
        List {
            Section {
                SearchHeader(
                    query: state.searchQuery,
                    isLoading: state.isSearchLoading,
                    error: state.searchLoadError
                )
            }
            Section { StoryRows(stories: state.searchResults) }
        }
        .listStyle(.insetGrouped)
        .background(.background)
        .overlay {
            // Empty-search-results overlay. The `!isSearchLoading` guard
            // suppresses the brief window during a debounced query
            // change where searchResults are stale-empty before the
            // new fetch lands.
            if !state.isSearchLoading
                && state.searchResults.isEmpty
                && !state.searchQuery.isEmpty {
                EmptyResultsOverlay(query: state.searchQuery)
            }
        }
    }
}

private struct StoriesList: View {
    let state: AppState
    @Environment(\.dispatch) private var dispatch

    var body: some View {
        List {
            Section {
                FeedHeaderCard(
                    storyCount: state.feedStories.count,
                    unreadCount: state.feedStories.lazy.filter { !$0.isRead }.count,
                    lastRefreshedAt: state.lastRefreshedAt,
                    loadError: state.feedLoadError
                )
            }
            Section { StoryRows(stories: state.feedStories) }
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
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            if let error {
                Text(error)
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
