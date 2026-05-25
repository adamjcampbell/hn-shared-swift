import SwiftUI
import HackerNewsReader

struct RootView: View {
    let core: Core
    @State private var presented: IdentifiedURL?
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            StoriesScreen()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .comments(let storyID):
                        CommentsScreen(storyID: storyID)
                    }
                }
        }
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

private enum Route: Hashable {
    case comments(storyID: String)
}

private struct StoriesScreen: View {
    @Environment(Model.self) private var model
    @Environment(\.sendMessage) private var sendMessage

    var body: some View {
        @Bindable var model = model
        StoriesContent()
            .searchable(text: $model.searchQuery, prompt: Strings.searchPlaceholder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .task {
                await sendMessage.run(.refresh)
            }
            .navigationTitle(Strings.appTitle)
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
                    subtitle: model.feedHeaderSubtitle,
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
            Text(status.error ?? Strings.loadingMore)
                .foregroundStyle(
                    status.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)
                )
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                let showError = status.error != nil && !status.isLoading

                ProgressView()
                    .id(spinId)
                    .opacity(showError ? 0 : 1)

                Button(Strings.tryAgain) { sendMessage(.loadMore) }
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
        ContentUnavailableView(
            Strings.searchNoResults(query),
            systemImage: "magnifyingglass"
        )
        .background(.background)
    }
}

private struct FeedHeaderCard: View {
    let subtitle: String
    let loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.feedTitle).font(.headline)
            Text(subtitle)
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
                Text(Strings.searchHeader(query)).font(.headline)
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
        NavigationLink(value: Route.comments(storyID: story.id)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(story.title)
                    .font(.body)
                    .foregroundStyle(story.isRead ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                Text(story.metaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(
                story.readActionLabel,
                systemImage: story.isRead ? "circle" : "checkmark.circle.fill"
            ) {
                sendMessage(.toggleRead(id: story.id))
            }
            .tint(.blue)
        }
    }
}

private struct CommentsScreen: View {
    let storyID: String
    @Environment(Model.self) private var model
    @Environment(\.sendMessage) private var sendMessage

    var body: some View {
        CommentsContent(storyID: storyID)
            .navigationTitle(Strings.commentsTitle)
            .toolbar {
                if model.storyRow(id: storyID)?.url != nil {
                    Button(Strings.openArticle, systemImage: "arrow.up.right.square") {
                        sendMessage(.openStoryURL(id: storyID))
                    }
                }
            }
            .task(id: storyID) {
                await sendMessage.run(.viewStory(id: storyID))
                await sendMessage.run(.loadComments(id: storyID))
            }
    }
}

private struct CommentsContent: View {
    let storyID: String
    @Environment(Model.self) private var model

    var body: some View {
        if let story = model.storyRow(id: storyID) {
            List {
                Section { CommentsStoryHeader(story: story) }
                CommentsSection(storyID: storyID, story: story)
            }
            .listStyle(.insetGrouped)
        } else {
            ContentUnavailableView(
                Strings.commentsMissingStory,
                systemImage: "exclamationmark.triangle"
            )
        }
    }
}

private struct CommentsStoryHeader: View {
    let story: StoryRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(story.title)
                .font(.headline)
                .foregroundStyle(story.isRead ? .secondary : .primary)
            Text(story.metaLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CommentsSection: View {
    let storyID: String
    let story: StoryRow
    @Environment(Model.self) private var model

    var body: some View {
        let rows = model.commentRows(storyID: storyID)
        let status = model.commentsStatus(storyID: storyID)
        Section {
            if !rows.isEmpty {
                ForEach(rows) { row in
                    CommentRowView(row: row)
                }
            } else if status.error != nil {
                LoadCommentsErrorRow(status: status, storyID: storyID)
            } else if status.isLoading || story.commentCount > 0 {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                ContentUnavailableView(
                    Strings.commentsNoComments,
                    systemImage: "bubble.left"
                )
            }
        }
    }
}

private struct CommentRowView: View {
    let row: CommentRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.metaLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(row.text)
                .font(.body)
        }
        .padding(.leading, CGFloat(min(row.depth, 8)) * 12)
    }
}

private struct LoadCommentsErrorRow: View {
    let status: LoadStatus
    let storyID: String
    @Environment(\.sendMessage) private var sendMessage

    var body: some View {
        HStack {
            Text(status.error ?? "")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(Strings.tryAgain) { sendMessage(.loadComments(id: storyID)) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
