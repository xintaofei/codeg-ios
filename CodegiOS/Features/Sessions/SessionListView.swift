import SwiftUI
import Combine

/// Lists a server's conversations grouped by folder (the iPad split's middle
/// column / the iPhone "Chats" tab root): a "Pinned" group on top, then one
/// group per folder, then an "Other" catch-all. Each group is an App Store-style
/// **card** showing a capped preview; tapping a card zoom-expands it to a
/// fullscreen list of that group's sessions (``SessionSectionFullScreen``).
/// Rows are tappable only inside the fullscreen list — the card itself owns the
/// tap. On iPad a row tap binds `selectedConversationID`; on iPhone the parent
/// passes `onOpen` to push instead. Global search lives in the system Search tab
/// on iPhone; regular width keeps a local `.searchable` filter that falls back to
/// a flat, directly-tappable result list. Select (the checkmark in the toolbar)
/// opens every group out into one pickable list, to move several conversations
/// to another folder at once.
struct SessionListView: View {
    let server: ServerProfile
    let client: CodegClient
    @Binding var selectedConversationID: Int?
    /// Compact navigation hook: when set, a row tap opens via this instead of
    /// writing the selection binding.
    var onOpen: ((Int) -> Void)?
    /// Compact: draws what a row in a group's fullscreen list opens, pushed on
    /// that cover's own stack (see ``SessionSectionFullScreen``).
    var routeScreen: RouteScreen?
    /// `AppModel.linkArrivals`: a link closes the group's fullscreen list (and
    /// whatever it pushed), so where the link went shows instead.
    var linkArrivals: Int
    /// Shows the "+" new-task affordance when provided.
    var onNewSession: (() -> Void)?
    /// Compact Chats root only: turns the leading title into a tappable server
    /// switcher (the big left title opens the menu — not just the collapsed
    /// centered one). `nil` on iPad, where the sidebar owns server switching, so
    /// a plain title is shown there.
    var serverSwitcher: ServerSwitcher?

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
    /// The conversation whose tags are being edited, or whose move is open,
    /// from a row's menu.
    @State private var tagging: ConversationSummary?
    @State private var moving: ConversationSummary?
    @State private var showTagFilter = false
    /// The picked conversations "Move to…" is open on (selection mode).
    @State private var batchMove: BatchMove?

    /// A selection as "Move to…" opened on it: the move runs on exactly these.
    private struct BatchMove: Identifiable {
        let id = UUID()
        let conversations: [ConversationSummary]
    }

    init(
        server: ServerProfile,
        client: CodegClient,
        selectedConversationID: Binding<Int?>,
        onOpen: ((Int) -> Void)? = nil,
        routeScreen: RouteScreen? = nil,
        linkArrivals: Int = 0,
        onNewSession: (() -> Void)? = nil,
        serverSwitcher: ServerSwitcher? = nil
    ) {
        self.server = server
        self.client = client
        self._selectedConversationID = selectedConversationID
        self.onOpen = onOpen
        self.routeScreen = routeScreen
        self.linkArrivals = linkArrivals
        self.onNewSession = onNewSession
        self.serverSwitcher = serverSwitcher
        self._viewModel = State(initialValue: SessionListViewModel(client: client))
    }

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
        // plain server name is the column title. Selecting, the title counts
        // the picks.
        .navigationTitle(titleText)
        .toolbarTitleDisplayMode(serverSwitcher == nil && !viewModel.isSelecting ? .automatic : .inline)
        .toolbar {
            if viewModel.isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { viewModel.endSelecting() }
                        .fontWeight(.semibold)
                        .tint(Theme.accent)
                        // The move's outcome decides what stays picked.
                        .disabled(viewModel.isMovingSelection)
                }
            } else {
                normalToolbar
            }
        }
        // Keyed on `serverRevision` so an in-place edit of the selected server
        // (same UUID, new URL/token → fresh `client`) rebinds the list to the
        // new endpoint and refetches, rather than serving the old endpoint's
        // sessions.
        .task(id: serverRevision) {
            viewModel.bindTagFilter(server: server.id.uuidString)
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
        // A tag write the server confirmed (from a row's picker here, or the
        // session screen's): patch the row rather than refetch per toggle.
        .onReceive(NotificationCenter.default.publisher(for: .conversationTagsDidChange)) { note in
            if let change = note.object as? ConversationTagsChange { viewModel.applyTagChange(change) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationTagDefinitionsDidChange)) { _ in
            Task { await viewModel.reloadTagDefinitions() }
        }
        .sessionRowSheets(rowActions, tagging: $tagging, moving: $moving)
        .sheet(isPresented: $showTagFilter) {
            TagFilterSheet(viewModel: viewModel, client: client)
        }
        // "Move to…" for the picks: the same sheet as a row's, on all of them.
        .sheet(item: $batchMove) { batch in
            MoveConversationSheet(conversations: batch.conversations, client: client) { folder, label in
                Task { await viewModel.moveSelection(batch.conversations, to: folder, label: label) }
            }
        }
        .transientNotice(viewModel.notice) { viewModel.dismissNotice() }
    }

    /// The title: the server's (the switcher draws it on compact), or — while
    /// selecting — how many are picked.
    private var titleText: Text {
        if viewModel.isSelecting {
            let count = viewModel.selection.count
            return count == 0 ? Text("Select Conversations") : Text("\(count) Selected")
        }
        return Text(verbatim: serverSwitcher == nil ? server.name : "")
    }

    /// The toolbar outside selection mode.
    @ToolbarContentBuilder
    private var normalToolbar: some ToolbarContent {
        if let serverSwitcher {
            ToolbarItem(placement: .topBarLeading) {
                serverTitleMenu(serverSwitcher)
            }
        }
        // Pick several conversations to move together — once there is one
        // that may move.
        if viewModel.hasLoaded, viewModel.canSelect {
            ToolbarItem(placement: .topBarTrailing) {
                Button { viewModel.beginSelecting() } label: {
                    Image(systemName: "checkmark.circle")
                }
                .tint(Theme.textSecondary)
                .accessibilityLabel("Select")
            }
        }
        // Only once there are tags to filter by (a saved filter whose tags
        // are all gone no longer applies, so it needs no way out).
        if !viewModel.tags.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                let active = viewModel.activeFilter.isActive
                Button { showTagFilter = true } label: {
                    Image(systemName: active
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .tint(active ? Theme.accent : Theme.textSecondary)
                .accessibilityLabel("Filter by tags")
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

    /// What the rows' menus run. A move is the list model's: it tells the
    /// outcome and refetches where everything landed.
    private var rowActions: SessionRowActions {
        SessionRowActions(client: client) { conversation, folder, label in
            Task { await viewModel.move(conversation, to: folder, label: label) }
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
            } else if viewModel.isSelecting {
                selectionList
            } else {
                sessionList
            }
        }
        // Cross-fade the first load into the list instead of a hard swap —
        // and the cards into the selection list and back.
        .transition(.opacity)
        .animation(Theme.Motion.content, value: viewModel.hasLoaded)
        .animation(Theme.Motion.content, value: viewModel.isSelecting)
    }

    // MARK: - Selection mode

    /// Selection mode (web Manage conversations): every group opened out into
    /// one sectioned `List` in edit mode, so a tap — or a swipe down the
    /// checkmarks — picks rows instead of opening them. The search and the tag
    /// filter still narrow it. A row that can't move (a sub-session) shows, but
    /// can't be picked. The picks go to "Move to…" from the bar at the bottom.
    private var selectionList: some View {
        let pinned = viewModel.pinned(searchText: searchText)
        let groups = viewModel.folderGroups(searchText: searchText).filter { !$0.conversations.isEmpty }
        let orphans = viewModel.ungrouped(searchText: searchText)
        let visible = pinned + groups.flatMap(\.conversations) + orphans

        return List(selection: selectionBinding) {
            // What narrows the list, here too: Select All covers only what shows.
            let filter = viewModel.activeFilter
            if filter.isActive {
                TagFilterBar(filter: filter, tagsByID: viewModel.tagsByID) { viewModel.setTagFilter($0) }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            }
            if !pinned.isEmpty {
                Section {
                    selectableRows(pinned, showFolder: true)
                } header: {
                    Text("Pinned")
                }
            }
            ForEach(groups) { group in
                Section {
                    selectableRows(group.conversations, showFolder: false)
                } header: {
                    Text(verbatim: group.folder.name)
                }
            }
            if !orphans.isEmpty {
                Section {
                    selectableRows(orphans, showFolder: true)
                } header: {
                    Text("Other")
                }
            }
            if visible.isEmpty {
                Text("No conversations to select")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        .refreshable { await viewModel.refresh() }
        .safeAreaInset(edge: .bottom) {
            selectionBar(visible: visible)
        }
    }

    private var selectionBinding: Binding<Set<Int>> {
        Binding(get: { viewModel.selection.ids }, set: { viewModel.setSelection($0) })
    }

    /// Display-only rows (no button, no menu): the list's selection owns the tap.
    private func selectableRows(_ conversations: [ConversationSummary], showFolder: Bool) -> some View {
        ForEach(conversations) { conversation in
            let pickable = ConversationSelection.canPick(conversation)
            SessionRow(
                conversation: conversation,
                isSelected: false,
                folderName: showFolder ? viewModel.folderNames[conversation.folderId] : nil,
                rowTags: viewModel.rowTags(for: conversation)
            )
            .opacity(pickable ? 1 : 0.45)
            .selectionDisabled(!pickable)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 8))
        }
    }

    /// Select All / Deselect All over the rows on screen, and "Move to…" for
    /// the picks — floating glass over the list's bottom edge.
    private func selectionBar(visible: [ConversationSummary]) -> some View {
        let coversAll = viewModel.selection.coversAll(visible)
        let anyPickable = visible.contains(where: ConversationSelection.canPick)
        let busy = viewModel.isMovingSelection
        return HStack(spacing: 12) {
            Button {
                viewModel.toggleSelectAll(visible)
            } label: {
                coversAll ? Text("Deselect All") : Text("Select All")
            }
            .buttonStyle(.glass)
            .tint(Theme.textPrimary)
            .disabled(!anyPickable || busy)

            Spacer(minLength: 8)

            Button {
                let picked = viewModel.selectedConversations
                guard !picked.isEmpty else { return }
                batchMove = BatchMove(conversations: picked)
            } label: {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.small).tint(Theme.onAccent)
                    } else {
                        Image(systemName: "folder")
                    }
                    Text("Move to…")
                }
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(viewModel.selection.isEmpty || busy)
        }
        .font(.subheadline.weight(.semibold))
        .controlSize(.large)
        .padding(.horizontal, Theme.Layout.screenHMargin)
        .padding(.top, 6)
        .padding(.bottom, 10)
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

                // What narrows the list, each tag removable.
                let filter = viewModel.activeFilter
                if filter.isActive {
                    TagFilterBar(filter: filter, tagsByID: viewModel.tagsByID) { viewModel.setTagFilter($0) }
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
            .animation(Theme.Motion.chrome, value: selectedConversationID)
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await viewModel.refresh() }
        // App Store-style zoom into the tapped group's full list. On a phone a
        // row pushes its conversation inside the cover; on an iPad it selects
        // the conversation for the detail column and closes the cover.
        .fullScreenCover(item: $expandedSection) { section in
            fullScreen(for: section)
        }
        .onChange(of: linkArrivals) { expandedSection = nil }
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
            rowTags: { viewModel.rowTags(for: $0) },
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
        LazyVStack(spacing: 0) {
            ForEach(matches) { conv in
                SessionRow(
                    conversation: conv,
                    isSelected: conv.id == selectedConversationID,
                    folderName: viewModel.folderNames[conv.folderId],
                    onTap: { select(conv) },
                    onTogglePin: { togglePin(conv) },
                    rowTags: viewModel.rowTags(for: conv),
                    onEditTags: { tagging = conv },
                    onMove: { moving = conv }
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
            rowTags: { viewModel.rowTags(for: $0) },
            // iPad: select for the detail column, then close the cover.
            onOpen: { id in open(id: id); expandedSection = nil },
            routeScreen: routeScreen,
            onTogglePin: { conv in togglePin(conv) },
            rowActions: rowActions,
            notice: viewModel.notice,
            onDismissNotice: { viewModel.dismissNotice() },
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
        } else if viewModel.isFilteredEmpty {
            // Every conversation filtered away: say so, and offer the way back.
            EmptyStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No conversations with these tags",
                actionTitle: "Clear filter",
                action: { viewModel.setTagFilter(.none) }
            )
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
