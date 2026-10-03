import SwiftUI

/// Root of the system search tab: server-side search across the selected
/// server's conversations (`list_all_conversations` with `search`), debounced
/// as you type, with locally stored recent searches when the field is empty.
/// Replaces the old hand-rolled in-list search field — on iOS 26 the search
/// tab role gives the field its native placement for free.
struct SearchView: View {
    let client: CodegClient?
    /// The session opened last (or open, on iPad); its row is marked.
    var markedConversationID: Int? = nil
    let onOpen: (Int) -> Void

    @State private var query = ""
    @State private var results: [ConversationSummary] = []
    @State private var folderNames: [Int: String] = [:]
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var error: String?
    @State private var recents: [String] = RecentSearches.load()

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .screenTitle("Search", compact: horizontalSizeClass == .compact)
        .searchable(text: $query, prompt: "Search sessions")
        .task(id: query) {
            await runSearch()
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if client == nil {
            EmptyStateView(
                icon: "server.rack",
                title: "No Server Selected",
                message: "Pick a server in the Chats tab to search its sessions."
            )
        } else if trimmedQuery.isEmpty {
            recentsList
        } else if isSearching, !hasSearched {
            LoadingView(label: "Searching…")
        } else if let error {
            InlineErrorView(message: error) {
                Task { await runSearch(force: true) }
            }
        } else if results.isEmpty, hasSearched {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No Matches",
                message: "No sessions match \"\(trimmedQuery)\"."
            )
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(results) { conversation in
                    SessionRow(
                        conversation: conversation,
                        isSelected: conversation.id == markedConversationID,
                        folderName: folderNames[conversation.folderId],
                        onTap: { open(conversation) }
                    )
                }
            }
            .padding(.horizontal, Theme.Layout.screenHMargin)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private var recentsList: some View {
        if recents.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "Search Sessions",
                message: "Find sessions by title across all of this server's folders."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Recent")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Clear") {
                            recents = []
                            RecentSearches.save([])
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 6)

                    ForEach(recents, id: \.self) { term in
                        Button {
                            query = term
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                                Text(term)
                                    .font(.body)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Theme.hairline)
                    }
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
            }
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Search

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runSearch(force: Bool = false) async {
        let term = trimmedQuery
        error = nil
        guard let client, !term.isEmpty else {
            results = []
            hasSearched = false
            isSearching = false
            return
        }
        // Debounce: typing cancels this task (`.task(id: query)`) and restarts it.
        if !force {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
        isSearching = true
        defer { isSearching = false }
        do {
            async let matches = client.listConversations(search: term)
            async let folders = client.listFolders()
            let (loaded, loadedFolders) = try await (matches, folders)
            guard !Task.isCancelled else { return }
            results = loaded.sorted { $0.updatedAt > $1.updatedAt }
            folderNames = Dictionary(loadedFolders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            hasSearched = true
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func open(_ conversation: ConversationSummary) {
        recents = RecentSearches.record(trimmedQuery, in: recents)
        onOpen(conversation.id)
    }
}

/// Tiny local store for recent search terms (most recent first, capped).
enum RecentSearches {
    private static let key = "codeg.recentSearches.v1"
    private static let cap = 10

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ terms: [String]) {
        UserDefaults.standard.set(terms, forKey: key)
    }

    /// Prepend a term (deduplicated, capped) and persist; returns the new list.
    static func record(_ term: String, in current: [String]) -> [String] {
        guard !term.isEmpty else { return current }
        var next = current.filter { $0.localizedCaseInsensitiveCompare(term) != .orderedSame }
        next.insert(term, at: 0)
        next = Array(next.prefix(cap))
        save(next)
        return next
    }
}
