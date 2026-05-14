import SwiftUI
import HackerNewsReader

struct RootView: View {
    @State private var core = UICore()
    @State private var presented: IdentifiedURL?

    var body: some View {
        NavigationStack { StoriesScreen(state: core.state) }
            .environment(\.sendEvent, SendAppEvent(core))
            .sheet(item: $presented) { item in
                SafariView(url: item.url)
                    .ignoresSafeArea()
            }
            .task {
                // Long-lived consumer of AppCommand. The sheet binding
                // lives here in the SwiftUI tree; user-driven dismissal
                // sets `presented = nil` without touching UICore.
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
    @Bindable var state: AppState
    @Environment(\.sendEvent) private var sendEvent

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
                await sendEvent.run(.refresh)
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
                    isLoading: state.search.initialStatus.isLoading,
                    error: state.search.initialStatus.error
                )
            }
            Section { StoryRows(stories: state.searchResults) }
            if state.search.loadedStories?.hasMore == true {
                Section {
                    LoadMoreRow(status: state.search.loadMoreStatus)
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
            if !state.search.initialStatus.isLoading
                && state.searchResults.isEmpty
                && !state.searchQuery.isEmpty {
                EmptyResultsOverlay(query: state.searchQuery)
            }
        }
    }
}

private struct StoriesList: View {
    let state: AppState
    @Environment(\.sendEvent) private var sendEvent

    var body: some View {
        List {
            Section {
                FeedHeaderCard(
                    storyCount: state.feedStories.count,
                    unreadCount: state.feedStories.lazy.filter { !$0.isRead }.count,
                    lastRefreshedAt: state.feed.loadedStories?.loadedAt,
                    loadError: state.feed.initialStatus.error
                )
            }
            Section { StoryRows(stories: state.feedStories) }
            if state.feed.loadedStories?.hasMore == true {
                Section {
                    LoadMoreRow(status: state.feed.loadMoreStatus)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await sendEvent.run(.refresh) }
    }
}

private struct LoadMoreRow: View {
    let status: LoadStatus
    @Environment(\.sendEvent) private var sendEvent

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

                Button("Try again") { sendEvent(.loadMore) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .opacity(showError ? 1 : 0)
                    .allowsHitTesting(showError)
            }
        }
        .animation(.default, value: status)
        .onAppear {
            spinId &+= 1
            sendEvent(.loadMore)
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
    @Environment(\.sendEvent) private var sendEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if story.url != nil {
                Button {
                    sendEvent(.openStory(id: story.id))
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
                sendEvent(.toggleRead(id: story.id))
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
