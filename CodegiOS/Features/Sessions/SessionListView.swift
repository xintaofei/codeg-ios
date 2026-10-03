import SwiftUI
import Combine

/// Lists a server's conversations grouped by folder (the iPad split's middle
/// column / the iPhone "Chats" tab root): a "Pinned" group on top, then one
/// group per folder, then an "Other" catch-all. Each group is an App Store-style
/// **card** showing a capped preview whose rows open their session directly;
/// the card's header (or "Show all") zoom-expands it to a fullscreen list of
/// that group's sessions (``SessionSectionFullScreen``). On iPad a row tap binds
/// `selectedConversationID`; on iPhone the parent passes `onOpen` to push
/// instead. Global search lives in the system Search tab on iPhone; regular
/// width keeps a local `.searchable` filter that falls back to a flat,
/// directly-tappable result list.
struct SessionListView: View {
    let server: ServerProfile
    let client: CodegClient
    @Binding var selectedConversationID: Int?
    /// Compact navigation hook: when set, a row tap opens via this instead of
    /// writing the selection binding.
    var onOpen: ((Int) -> Void)?
    /// Shows the "+" new-task affordance when provided.
    var onNewSession: (() -> Void)?
    /// Compact Chats root only: turns the leading title into a tappable server
    /// switcher (the big left title opens the menu — not just the collapsed
    /// centered one). `nil` on iPad, where the sidebar owns server switching, so
    /// a plain title is shown there.
    var serverSwitcher: ServerSwitcher?
    /// The session to mark as the one you came from (iPhone, where nothing
    /// stays selected). iPad marks `selectedConversationID` instead.
    var markedConversationID: Int?

    /// Configuration for the leading server-switcher title menu.
    struct ServerSwitcher {
        let servers: [ServerProfile]
        let selection: Binding<ServerProfile.ID?>
        let onManage: () -> Void
    }

    @State private var viewModel: SessionListViewModel
    @State private var searchText = ""
    /// The group currently zoom-expanded to fullscreen, or `nil`.
    @State private var expandedSection: ChatExpand?
    /// Shared namespace pairing each card's `matchedTransitionSource` with the
    /// fullscreen's `.navigationTransition(.zoom)`.
    @Namespace private var cardNS
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        server: ServerProfile,
        client: CodegClient,
        selectedConversationID: Binding<Int?>,
        onOpen: ((Int) -> Void)? = nil,
        onNewSession: (() -> Void)? = nil,
        serverSwitcher: ServerSwitcher? = nil,
        markedConversationID: Int? = nil
    ) {
        self.server = server
        self.client = client
        self._selectedConversationID = selectedConversationID
        self.onOpen = onOpen
        self.onNewSession = onNewSession
        self.serverSwitcher = serverSwitcher
        self.markedConversationID = markedConversationID
        self._viewModel = State(initialValue: SessionListViewModel(client: client))
    }

    /// The row drawn as the current one: the open session on iPad, the one
    /// opened last on iPhone.
    private var markedID: Int? { markedConversationID ?? selectedConversationID }

    private var searching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Identity of the data source. Changes when the server is switched OR when
    /// the *currently selected* server is edited in place (same UUID, new
    /// URL/token) — in which case `client` is a fresh instance pointing at the
    /// new endpoint. Keying `.task` on this rebinds the view model to the new
    /// client and reloads, instead of serving the old endpoint's sessions.
    private var serverRevision: String {
        "\(server.id.uuidString)|\(client.baseURL.absoluteString)|\(client.token)"
    }

    var body: some View {
        // Regular width gets a local `.searchable` filter (top placement there);
        // compact relies on the system Search tab instead, so no field at all.
        if horizontalSizeClass == .regular {
            main.searchable(text: $searchText, prompt: "Filter sessions")
        } else {
            main
        }
    }

    private var main: some View {
        ZStack {
            CodegBackground()
            content
        }
        // With the leading switcher the title is rendered by the menu itself, so
        // suppress the system (centered) title to avoid a duplicate; on iPad the
        // plain server name is the column title.
        .navigationTitle(serverSwitcher == nil ? server.name : "")
        .toolbarTitleDisplayMode(serverSwitcher == nil ? .automatic : .inline)
        .toolbar {
            if let serverSwitcher {
                ToolbarItem(placement: .topBarLeading) {
                    serverTitleMenu(serverSwitcher)
                }
            }
            if let onNewSession {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onNewSession) {
                        // A compose/pencil glyph (matches codeg's "new" icon)
                        // reads more clearly as "start a task" than a bare "+".
                        Image(systemName: "square.and.pencil")
                    }
                    .tint(Theme.accent)
                    .accessibilityLabel("New Task")
                }
            }
            // No explicit refresh button — pull-to-refresh covers it (the list
            // also reloads on server switch / in-place edit).
        }
        // Keyed on `serverRevision` so an in-place edit of the selected server
        // (same UUID, new URL/token → fresh `client`) rebinds the list to the
        // new endpoint and refetches, rather than serving the old endpoint's
        // sessions.
        .task(id: serverRevision) {
            await viewModel.reload(client: client)
        }
        // A conversation mutated from the detail screen (rename / pin / status /
        // delete) posts this; refetch so the row reflects it — or drops, if
        // deleted — instead of going stale (there's no on-appear reload).
        .onReceive(NotificationCenter.default.publisher(for: .conversationsDidChange)) { _ in
            Task { await viewModel.refresh() }
        }
        // A worktree folder registered from the branch switcher changes the folder
        // grouping — refetch so the new group/merge shows without waiting.
        .onReceive(NotificationCenter.default.publisher(for: .foldersDidChange)) { _ in
            Task { await viewModel.refresh() }
        }
    }

    // MARK: - Content states

    private var content: some View {
        Group {
            if viewModel.isLoading, !viewModel.hasLoaded {
                LoadingView(label: "Loading sessions…")
            } else if let error = viewModel.error, !viewModel.hasLoaded {
                InlineErrorView(message: error) {
                    Task { await viewModel.load() }
                }
            } else {
                sessionList
            }
        }
        // Cross-fade the first load into the list instead of a hard swap.
        .transition(.opacity)
        .animation(Theme.Motion.content, value: viewModel.hasLoaded)
    }

    private var sessionList: some View {
        let pinnedConvs = viewModel.pinned(searchText: searchText)
        let groups = viewModel.folderGroups(searchText: searchText)
        let orphans = viewModel.ungrouped(searchText: searchText)
        // Nothing to show in any group (empty server, folders-but-no-sessions, or
        // a search with no matches) → the empty state, not a wall of empty cards.
        let isEmpty = pinnedConvs.isEmpty && orphans.isEmpty
            && groups.allSatisfy { $0.conversations.isEmpty }

        return ScrollView {
            LazyVStack(spacing: 12) {
                // A failed refresh over a list that still has rows: surface the
                // error inline above the cards rather than swallowing it.
                if let error = viewModel.error, !viewModel.conversations.isEmpty {
                    RefreshErrorBanner(
                        message: error,
                        retry: { Task { await viewModel.refresh() } },
                        dismiss: { viewModel.dismissError() }
                    )
                    .padding(.horizontal, Theme.Layout.screenHMargin)
                }

                if isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: 360)
                        .padding(.horizontal, Theme.Layout.screenHMargin)
                } else if searching {
                    // Search (iPad `.searchable` only): a flat, directly-tappable
                    // result list — capped preview cards would hide matches behind
                    // an extra tap.
                    searchResults(pinned: pinnedConvs, groups: groups, orphans: orphans)
                } else {
                    sectionCards(pinned: pinnedConvs, groups: groups, orphans: orphans)
                }
            }
            .padding(.top, Theme.Layout.screenTopInset)
            .padding(.bottom, Theme.Layout.screenBottomInset)
            .animation(Theme.Motion.chrome, value: markedID)
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await viewModel.refresh() }
        // App Store-style zoom into the tapped group's full list. A row tap opens
        // the conversation *then* clears this binding (see `fullScreen(for:)`), so
        // the cover's dismissal reveals the already-pushed detail in one motion —
        // no flash of this list in between.
        .fullScreenCover(item: $expandedSection) { section in
            fullScreen(for: section)
        }
    }

    // MARK: - Cards

    /// One card per group: Pinned, each non-empty folder, then Other.
    @ViewBuilder
    private func sectionCards(
        pinned: [ConversationSummary],
        groups: [SessionListViewModel.FolderGroup],
        orphans: [ConversationSummary]
    ) -> some View {
        if !pinned.isEmpty {
            card(.pinned, title: "Pinned",
                 tint: Theme.accent, conversations: pinned, showFolder: true)
        }
        ForEach(groups.filter { !$0.conversations.isEmpty }) { group in
            card(.folder(group.folder.id), title: group.folder.name,
                 tint: Color(hexString: group.folder.color) ?? Theme.accent,
                 conversations: group.conversations, showFolder: false)
        }
        if !orphans.isEmpty {
            card(.other, title: "Other",
                 tint: Theme.textSecondary, conversations: orphans, showFolder: true)
        }
    }

    private func card(
        _ section: ChatExpand, title: String, tint: Color,
        conversations: [ConversationSummary], showFolder: Bool
    ) -> some View {
        SessionSectionCard(
            title: title,
            tint: tint,
            conversations: conversations,
            folderName: { showFolder ? viewModel.folderNames[$0.folderId] : nil },
            markedID: markedID,
            onOpen: { open(id: $0) },
            onTogglePin: { togglePin($0) },
            onExpand: { expandedSection = section }
        )
        .matchedTransitionSource(id: section.id, in: cardNS)
        .padding(.horizontal, Theme.Layout.screenHMargin)
    }

    /// Flat, directly-tappable matches for the iPad search filter (no cards).
    @ViewBuilder
    private func searchResults(
        pinned: [ConversationSummary],
        groups: [SessionListViewModel.FolderGroup],
        orphans: [ConversationSummary]
    ) -> some View {
        // pinned / folder-groups / orphans are mutually exclusive, so this never
        // double-counts a conversation. Lazy so a broad match set stays smooth on
        // large servers (matches the old flat list's virtualization).
        let matches = pinned + groups.flatMap(\.conversations) + orphans
        LazyVStack(spacing: 8) {
            ForEach(matches) { conv in
                SessionRow(
                    conversation: conv,
                    isSelected: conv.id == markedID,
                    folderName: viewModel.folderNames[conv.folderId],
                    onTap: { select(conv) },
                    onTogglePin: { togglePin(conv) }
                )
            }
        }
        // Match the flat result list in the Search tab (`SearchView.resultsList`)
        // and the card grid above — all at the shared screen margin.
        .padding(.horizontal, Theme.Layout.screenHMargin)
    }

    // MARK: - Fullscreen

    @ViewBuilder
    private func fullScreen(for section: ChatExpand) -> some View {
        let data = sectionData(section)
        SessionSectionFullScreen(
            title: data.title,
            tint: data.tint,
            conversations: data.conversations,
            folderName: { data.showFolder ? viewModel.folderNames[$0.folderId] : nil },
            markedID: markedID,
            // Open first (pushes the detail onto the nav stack behind the cover),
            // then dismiss — so closing the cover reveals the detail directly
            // instead of zooming back to this list and pushing afterward.
            onOpen: { id in open(id: id); expandedSection = nil },
            onTogglePin: { conv in togglePin(conv) },
            onClose: { expandedSection = nil }
        )
        .navigationTransition(.zoom(sourceID: section.id, in: cardNS))
    }

    /// Live-reads the section's current rows from the view model (never a frozen
    /// snapshot) so a background refresh while the fullscreen is open stays fresh.
    private func sectionData(_ section: ChatExpand)
        -> (title: String, tint: Color, conversations: [ConversationSummary], showFolder: Bool) {
        switch section {
        case .pinned:
            return ("Pinned", Theme.accent, viewModel.pinned(searchText: ""), true)
        case .folder(let fid):
            let group = viewModel.folderGroups(searchText: "").first { $0.folder.id == fid }
            let tint = group.flatMap { Color(hexString: $0.folder.color) } ?? Theme.accent
            return (group?.folder.name ?? "Folder", tint, group?.conversations ?? [], false)
        case .other:
            return ("Other", Theme.textSecondary, viewModel.ungrouped(searchText: ""), true)
        }
    }

    /// One expandable chat section. Its `id` doubles as the zoom-transition
    /// source id and selects the live row list in `sectionData`.
    private enum ChatExpand: Identifiable, Hashable {
        case pinned
        case folder(Int)
        case other
        var id: String {
            switch self {
            case .pinned: return "pinned"
            case .folder(let fid): return "folder-\(fid)"
            case .other: return "other"
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.error != nil {
            // A refresh failed and left no rows to show — full retry affordance.
            InlineErrorView(message: viewModel.error ?? "") {
                Task { await viewModel.refresh() }
            }
        } else if searching {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No Matches",
                message: "No sessions match \"\(searchText)\"."
            )
        } else if let onNewSession {
            EmptyStateView(
                icon: "tray",
                title: "No Sessions",
                message: "Start your first task and watch the agent work from here.",
                actionTitle: "Start a Task",
                action: onNewSession
            )
        } else {
            EmptyStateView(
                icon: "tray",
                title: "No Sessions",
                message: "No sessions on this server yet."
            )
        }
    }

    // MARK: - Actions & helpers

    private func select(_ conversation: ConversationSummary) {
        open(id: conversation.id)
    }

    /// Open a conversation by id — pushes (compact) or binds the selection (iPad).
    private func open(id: Int) {
        if let onOpen {
            onOpen(id)
        } else {
            selectedConversationID = id
        }
    }

    private func togglePin(_ conversation: ConversationSummary) {
        Task { await viewModel.setPinned(conversation, pinned: !conversation.isPinned) }
    }

    /// The big, left-aligned server name rendered as a `Menu` so it's tappable in
    /// place (not only when collapsed to the centered toolbar title). A chevron
    /// signals the affordance; the picker carries a checkmark on the current
    /// server. `.fixedSize()` keeps a long name from collapsing to "…".
    private func serverTitleMenu(_ switcher: ServerSwitcher) -> some View {
        Menu {
            // Grouped sections (a header + a separated actions block) read far
            // cleaner in a menu than a bare Divider above a lone button.
            Section("Switch Server") {
                Picker("Server", selection: switcher.selection) {
                    ForEach(switcher.servers) { server in
                        Text(server.name).tag(Optional(server.id))
                    }
                }
                .pickerStyle(.inline)
            }
            // Plain text (no icon): a system menu draws a button's icon on the
            // trailing edge, which would clash with the leading checkmark column
            // above. Without an icon, the title lines up under the server names.
            Section {
                Button("Manage Servers…", action: switcher.onManage)
            }
        } label: {
            HStack(spacing: 5) {
                Text(server.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .fixedSize()
        }
        .accessibilityLabel("Server: \(server.name)")
        .accessibilityHint("Switch server")
    }
}
