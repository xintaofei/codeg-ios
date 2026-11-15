import Foundation
import Observation

/// Drives ``SessionListView``: loads folders + conversations for one server and
/// derives the *grouped* display — a "Pinned" group plus one collapsible group
/// per folder. Pinned conversations appear ONLY in the Pinned group (ordered by
/// `pinnedAt`); each folder group lists its non-pinned conversations newest-first.
///
/// The full conversation list is kept in memory and grouped/filtered locally, so
/// search typing and pin toggles stay instant without re-hitting the network.
@MainActor
@Observable
final class SessionListViewModel {
    /// HTTP client for the current server. Swappable: if the selected server is
    /// edited in place (same identity, new URL/token), the view feeds in a fresh
    /// client via `reload(client:)` so subsequent fetches hit the new endpoint.
    private var client: CodegClient

    /// The full folder set (`list_all_folder_details`); used only for the by-id
    /// `folderNames` label lookup (so a worktree/chat folder id still resolves).
    private(set) var folders: [FolderDetail] = []
    /// The workspace-visible set (`list_open_folder_details`); the source for the
    /// displayed folder groups after ``FolderVisibility`` hides worktree children.
    private(set) var openFolders: [FolderDetail] = []
    /// Whether `openFolders` has loaded at least once (see `displaySource`): until
    /// then the groups fall back to the full set; after, an empty result is honored.
    private var openFoldersLoaded = false
    /// Full, unfiltered conversation list as returned by the server. Grouping /
    /// search ordering is applied at the derived-data accessors below.
    private(set) var conversations: [ConversationSummary] = []

    /// Every tag this server has, for the rows' chips and the filter. A server
    /// without tags (or a failed read) only goes without chips.
    private(set) var tags: [ConversationTag] = [] {
        didSet { tagsByID = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    private(set) var tagsByID: [Int: ConversationTag] = [:]
    private(set) var branchTag = BranchTagSetting()
    /// The tag filter as saved for this server. It may still name tags deleted
    /// since — ``activeFilter`` is what applies.
    private(set) var tagFilter: TagFilter = .none
    /// The server profile the filter is saved under.
    private var tagFilterServer: String?

    /// `true` while the initial full-screen load is in flight (drives the
    /// loader vs. list decision). Refreshes do NOT set this — they keep the
    /// existing list on screen and report progress via `isRefreshing`.
    private(set) var isLoading = false
    /// `true` while a pull-to-refresh / toolbar refresh is in flight.
    private(set) var isRefreshing = false
    /// User-facing error message for the most recent load/refresh/pin, if it failed.
    private(set) var error: String?
    /// A one-shot line (a move's outcome), shown for a few seconds.
    private(set) var notice: String?

    /// Monotonic token so a slow fetch can't clobber a newer one's results.
    private var fetchGeneration = 0

    /// Consecutive fetches where *both* endpoints failed (after retries). Debounces
    /// the error banner: while rows are already on screen, a lone failed refresh is
    /// swallowed (stale rows stay) and the banner appears only once the outage
    /// persists — see `failuresBeforeAlerting`.
    private var consecutiveFailures = 0
    /// How many back-to-back full failures before the banner shows over existing
    /// rows. The first miss is hidden; the second surfaces it.
    private static let failuresBeforeAlerting = 2

    init(client: CodegClient) {
        self.client = client
    }

    /// `true` once a successful load has populated `conversations`/`folders`.
    /// Used to decide between the full-screen loader and inline refresh spinner.
    private(set) var hasLoaded = false

    /// Whether the toolbar refresh affordance should be disabled — true while
    /// any fetch (initial or refresh) is in flight.
    var isBusy: Bool { isLoading || isRefreshing }

    /// Clears a surfaced error banner (e.g. a failed refresh over a list that
    /// still has rows). The next fetch also clears it.
    func dismissError() { error = nil }

    // MARK: - Derived data

    /// One folder and the (non-pinned) conversations shown under its group.
    struct FolderGroup: Identifiable {
        let folder: FolderDetail
        let conversations: [ConversationSummary]
        var id: Int { folder.id }
    }

    /// The folder set the groups derive from: the open set normally, the FULL set
    /// as a fallback when only the open-folders endpoint failed — so groups degrade
    /// to showing everything rather than dumping every chat into "Other".
    private var displaySource: [FolderDetail] { openFoldersLoaded ? openFolders : folders }

    /// Worktree-child folder id → root id over `displaySource`. Computed so it
    /// always tracks the rendered set (never stale vs `conversations`).
    var childToParent: [Int: Int] { FolderVisibility.childToParent(displaySource) }

    /// Folders that get a group header: open + regular with worktree children of
    /// an open root hidden, sorted by server `sortOrder` then name. A worktree's
    /// conversations fold into its root group (see `folderGroups`).
    var sortedFolders: [FolderDetail] {
        FolderVisibility.visibleFolders(displaySource).sorted {
            $0.sortOrder != $1.sortOrder
                ? $0.sortOrder < $1.sortOrder
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// `folderId -> name` lookup for the dim folder label shown on pinned rows
    /// (which span folders, so the row notes which folder it belongs to).
    var folderNames: [Int: String] {
        Dictionary(folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Pinned conversations across all folders, most-recently-pinned first,
    /// after applying the search and tag filters.
    func pinned(searchText: String) -> [ConversationSummary] {
        matching(conversations.filter(\.isPinned), searchText, activeFilter)
            .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
    }

    /// One group per folder (in `sortedFolders` order) holding that folder's
    /// non-pinned conversations, newest-first. With no search or tag filter
    /// every folder is included — even empty ones, so their collapsible header
    /// still shows; otherwise folders the narrowing leaves empty are dropped
    /// (web `matchesTagFilter`).
    func folderGroups(searchText: String) -> [FolderGroup] {
        let filter = activeFilter
        let narrowing = !trimmed(searchText).isEmpty || filter.isActive
        // Group by the merge target so a worktree's conversations land under its
        // root folder's header (matching the web), not a hidden worktree row.
        let map = childToParent
        let unpinnedByGroup = Dictionary(grouping: conversations.filter { !$0.isPinned }) {
            FolderVisibility.mergedFolderId($0.folderId, childToParent: map)
        }
        return sortedFolders.compactMap { folder in
            let convs = matching(unpinnedByGroup[folder.id] ?? [], searchText, filter)
                .sorted { $0.updatedAt > $1.updatedAt }
            if narrowing, convs.isEmpty { return nil }
            return FolderGroup(folder: folder, conversations: convs)
        }
    }

    /// Non-pinned conversations whose (merged) folder isn't a visible group —
    /// orphans / chat-folder sessions — shown in a trailing "Other" group.
    /// Newest-first, search- and tag-filtered. Normally empty: a safety net so
    /// a conversation never silently disappears.
    func ungrouped(searchText: String) -> [ConversationSummary] {
        let map = childToParent
        let known = Set(sortedFolders.map(\.id))
        return matching(conversations.filter {
            !$0.isPinned && !known.contains(FolderVisibility.mergedFolderId($0.folderId, childToParent: map))
        }, searchText, activeFilter)
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Filter a slice of conversations by the search query (title / model) and
    /// the tag filter.
    private func matching(_ convs: [ConversationSummary], _ searchText: String,
                          _ filter: TagFilter) -> [ConversationSummary] {
        let query = trimmed(searchText)
        guard !query.isEmpty || filter.isActive else { return convs }
        return convs.filter { conv in
            guard filter.matches(conv) else { return false }
            guard !query.isEmpty else { return true }
            if conv.displayTitle.localizedCaseInsensitiveContains(query) { return true }
            if let model = conv.model, model.localizedCaseInsensitiveContains(query) { return true }
            return false
        }
    }

    // MARK: - Tags

    /// The filter that applies: only tags that still exist, once the tags have
    /// loaded (until then a saved id can't be told from a deleted one).
    var activeFilter: TagFilter {
        tags.isEmpty ? .none : tagFilter.pruned(known: Set(tagsByID.keys))
    }

    /// Every conversation is filtered away (while there are some): the list
    /// says so and offers the way back, rather than looking empty.
    var isFilteredEmpty: Bool {
        let filter = activeFilter
        return filter.isActive && !conversations.isEmpty && !conversations.contains(where: filter.matches)
    }

    /// Take the filter saved for `server` — tag ids are a server's own.
    func bindTagFilter(server: String) {
        guard server != tagFilterServer else { return }
        tagFilterServer = server
        tagFilter = TagFilterStore.load(server: server)
    }

    /// Change the tag filter; kept for this server.
    func setTagFilter(_ filter: TagFilter) {
        tagFilter = filter
        if let server = tagFilterServer { TagFilterStore.save(filter, server: server) }
    }

    /// What a row draws after its title.
    func rowTags(for conversation: ConversationSummary) -> RowTags {
        RowTags.resolve(conversation, tagsByID: tagsByID, branchTag: branchTag)
    }

    /// The server confirmed a conversation's tags (a picker's write): patch the
    /// row in place. A refetch per toggle could land behind the next toggle.
    func applyTagChange(_ change: ConversationTagsChange) {
        conversations.applyTagChange(change, endpoint: client.tagEndpoint)
    }

    /// Re-read the tag definitions and the branch tag (a tag was created,
    /// renamed, recoloured, reordered or deleted somewhere).
    func reloadTagDefinitions() async {
        let client = self.client
        let endpoint = client.tagEndpoint
        async let tagRead = SessionListViewModel.optionalRead { try await client.listConversationTags() }
        async let branchRead = SessionListViewModel.optionalRead { try await client.conversationBranchTag() }
        let loadedTags = await tagRead
        let loadedBranch = await branchRead
        // Switched servers meanwhile: these ids are the other server's.
        guard endpoint == self.client.tagEndpoint else { return }
        if let loadedTags { tags = loadedTags }
        if let loadedBranch { branchTag = loadedBranch }
    }

    /// A read whose failure only means going without (tags dress the rows; a
    /// server without them must still list its conversations).
    nonisolated private static func optionalRead<T>(_ read: () async throws -> T) async -> T? {
        try? await read()
    }

    // MARK: - Pinning

    /// Optimistically pin/unpin a conversation, then persist to the server. On
    /// failure (e.g. an older server without the route) the local change reverts
    /// and `error` is surfaced. The optimistic `pinnedAt` is a local stand-in for
    /// ordering only; the next refresh replaces it with the server's value.
    func setPinned(_ conversation: ConversationSummary, pinned: Bool) async {
        guard let idx = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        let previous = conversations[idx].pinnedAt
        conversations[idx].pinnedAt = pinned ? Date() : nil
        do {
            try await client.setPinned(conversationId: conversation.id, pinned: pinned)
        } catch {
            if let i = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[i].pinnedAt = previous
            }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Moving

    func dismissNotice() { notice = nil }

    /// Move `conversation` to `folder` (named `label` in the outcome). Nothing
    /// optimistic: the server decides — a busy conversation is skipped — and
    /// the refetch after it shows where everything landed.
    func move(_ conversation: ConversationSummary, to folder: FolderDetail, label: String) async {
        let client = self.client
        guard let result = await requestMove([conversation.id], to: folder, on: client) else { return }
        notice = ConversationMove.message(for: result, conversationID: conversation.id, folderName: label)
        await followMove(result, requested: [conversation.id], to: folder, on: client)
    }

    /// Ask `client`'s server to move `ids`; nil (and the failure told) when the
    /// request itself failed — nothing moved then.
    private func requestMove(_ ids: [Int], to folder: FolderDetail, on client: CodegClient) async -> MoveConversationsResult? {
        do {
            return try await client.moveConversations(conversationIds: ids, targetFolderId: folder.id)
        } catch {
            notice = ConversationMove.failure(error)
            return nil
        }
    }

    /// Tell the app what moved, then show where everything landed.
    private func followMove(_ result: MoveConversationsResult, requested: [Int], to folder: FolderDetail,
                            on client: CodegClient) async {
        let moved = ConversationMove.batchOutcome(of: result, requested: requested).moved
        guard !moved.isEmpty else { return }
        // A session screen open on one of them lets go of the old folder's
        // connection — each moved conversation is told on its own.
        let endpoint = client.baseURL.absoluteString
        for id in moved {
            NotificationCenter.default.post(
                name: .conversationDidMove,
                object: ConversationMovedChange(endpoint: endpoint, conversationID: id, folderID: folder.id)
            )
        }
        // Other screens holding the rows (Activity, the folder lists) refetch.
        NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
        // Not `refresh()`: one already running may predate the move, and this
        // one supersedes it.
        await fetch(isInitial: false)
    }

    // MARK: - Selecting (move several at once)

    /// The list is picking conversations for one "Move to…" (web Manage
    /// conversations): its rows pick rather than open.
    private(set) var isSelecting = false
    private(set) var selection = ConversationSelection()
    /// A move of the picked conversations is out.
    private(set) var isMovingSelection = false

    /// Whether anything listed could be picked (the toolbar's Select).
    var canSelect: Bool { conversations.contains(where: ConversationSelection.canPick) }

    func beginSelecting() {
        selection = ConversationSelection()
        isSelecting = true
    }

    func endSelecting() {
        isSelecting = false
        selection = ConversationSelection()
    }

    /// What the list's selection hands back.
    func setSelection(_ ids: Set<Int>) {
        selection.set(ids, among: conversations)
    }

    /// Select All / Deselect All over the rows on screen.
    func toggleSelectAll(_ visible: [ConversationSummary]) {
        selection.toggleAll(visible)
    }

    /// The picked conversations, in list order.
    var selectedConversations: [ConversationSummary] { selection.picked(from: conversations) }

    /// Move `picked` — the selection as "Move to…" opened on it — to `folder`
    /// (named `label` in the outcome). One request; the server judges each
    /// conversation on its own and says which moved. Those leave the
    /// selection; the ones it left behind stay picked for another go, and the
    /// list stays in selection mode for them. Every one moved: selection mode
    /// ends.
    func moveSelection(_ picked: [ConversationSummary], to folder: FolderDetail, label: String) async {
        let ids = picked.map(\.id)
        guard !ids.isEmpty, !isMovingSelection else { return }
        let client = self.client
        isMovingSelection = true
        defer { isMovingSelection = false }
        guard let result = await requestMove(ids, to: folder, on: client) else { return }
        // Switched servers meanwhile: this selection is the other server's.
        if client.baseURL == self.client.baseURL {
            notice = ConversationMove.batchMessage(for: result, requested: ids, folderName: label)
            selection.settle(result)
            if ConversationMove.batchOutcome(of: result, requested: ids).movedAll { endSelecting() }
        }
        await followMove(result, requested: ids, to: folder, on: client)
    }

    // MARK: - Loading

    /// Initial load. Shows the full-screen loader and clears any prior error.
    /// No-op if a fetch is already running.
    func load() async {
        guard !isBusy else { return }
        await fetch(isInitial: true)
    }

    /// Identity of the endpoint the current data was loaded from, so a `.task`
    /// re-invocation with an unchanged endpoint doesn't needlessly wipe the list.
    private var loadedEndpoint: String?

    /// (Re)load against a possibly-new client. Called from `.task(id:)` keyed on
    /// the server + endpoint, so when the selected server is edited in place
    /// (same UUID, new URL/token) the list rebinds to the new client and
    /// refetches instead of silently serving the old endpoint's data.
    ///
    /// Only force-clears the visible list when the endpoint actually changed; a
    /// plain re-invocation for the same endpoint behaves like a quiet reload.
    func reload(client: CodegClient) async {
        let endpoint = "\(client.baseURL.absoluteString)|\(client.token)"
        let endpointChanged = endpoint != loadedEndpoint
        // Rewritten only for another endpoint: a client is no value the
        // view model can compare, so every write would redraw the list.
        if endpointChanged {
            self.client = client
            loadedEndpoint = endpoint
        }
        if !endpointChanged, hasLoaded {
            // The tab came back (a `TabView` runs `.task` again on every
            // appear): the list on screen stays, read again quietly only once
            // it has aged — a refetch per switch put the loading state and
            // the reads' results through the list just as the page came in.
            // What changes in the meantime from this device is announced
            // (`conversationsDidChange`) and read at once.
            if let lastFetchedAt, Date().timeIntervalSince(lastFetchedAt) < Self.reappearRefetchAge { return }
            await fetch(isInitial: false)
            return
        }
        await fetch(isInitial: true, force: endpointChanged)
    }

    /// When a fetch last brought the list in.
    @ObservationIgnored private var lastFetchedAt: Date?
    /// How old the list may be when its tab comes back before it is read again.
    static let reappearRefetchAge: TimeInterval = 30

    /// Pull-to-refresh / toolbar refresh. Keeps the current list on screen
    /// while refetching. No-op if a fetch is already running, so rapid taps
    /// or an overlapping pull can't race each other.
    func refresh() async {
        guard !isBusy else { return }
        await fetch(isInitial: false)
    }

    /// - Parameter force: when `true` (client/endpoint changed) the current
    ///   list/folders are cleared so the full-screen loader shows for the new
    ///   endpoint rather than briefly serving the previous server's rows.
    private func fetch(isInitial: Bool, force: Bool = false) async {
        fetchGeneration += 1
        let token = fetchGeneration
        if force {
            // New endpoint — drop the old data so the loader (not stale rows) shows.
            hasLoaded = false
            folders = []
            openFolders = []
            openFoldersLoaded = false
            conversations = []
            tags = []
            branchTag = BranchTagSetting()
            // Picks are the old server's conversations.
            endSelecting()
        }
        if isInitial { isLoading = true } else { isRefreshing = true }
        error = nil
        defer {
            // Only the current (newest) fetch may clear the busy flags, so a
            // superseded fetch finishing late can't switch the spinner off while
            // its replacement is still running.
            if token == fetchGeneration {
                isLoading = false
                isRefreshing = false
            }
        }

        // Two independent reads, each with its own retry; one failing no longer
        // fails the whole refresh. The tag reads ride alongside and only ever
        // cost the chips: they never fail the list.
        let client = self.client
        async let snapshot = client.loadServerSnapshot()
        async let tagRead = SessionListViewModel.optionalRead { try await client.listConversationTags() }
        async let branchRead = SessionListViewModel.optionalRead { try await client.conversationBranchTag() }
        let result = await snapshot
        let loadedTags = await tagRead
        let loadedBranch = await branchRead

        // A newer fetch superseded this one, or the view went away — discard.
        guard token == fetchGeneration else { return }
        if result.cancelled { return }

        adopt(folders: result.folders, openFolders: result.openFolders, conversations: result.conversations,
              tags: loadedTags, branchTag: loadedBranch)

        if result.anySucceeded {
            hasLoaded = true
            lastFetchedAt = Date()
            consecutiveFailures = 0
            error = nil
        } else {
            // Both endpoints failed after retries. Debounce the banner: keep the
            // stale rows visible on the first miss and surface it only once the
            // outage persists — unless nothing has loaded yet (initial load), where
            // the error must show so the user isn't left staring at a blank screen.
            consecutiveFailures += 1
            if !hasLoaded || consecutiveFailures >= Self.failuresBeforeAlerting {
                error = result.message
            }
        }
    }

    /// Commit one fetch's reads. Partial success degrades gracefully: whichever
    /// read returned applies, and a nil (a read that failed) keeps the prior
    /// value. Also the seam the grouping tests feed.
    func adopt(folders: [FolderDetail]?, openFolders: [FolderDetail]?, conversations: [ConversationSummary]?,
               tags: [ConversationTag]? = nil, branchTag: BranchTagSetting? = nil) {
        if let folders { self.folders = folders }
        if let openFolders { self.openFolders = openFolders; openFoldersLoaded = true }
        if let conversations {
            self.conversations = conversations
            // A picked conversation deleted (or turned unmovable) elsewhere
            // is no longer picked. Pruned on a copy: a mutation in place
            // tells every reader of the picks, changed or not (an assignment
            // of an equal value tells no one), and a refetch mostly prunes
            // nothing.
            var pruned = selection
            pruned.prune(to: conversations)
            if pruned != selection { selection = pruned }
        }
        if let tags { self.tags = tags }
        if let branchTag { self.branchTag = branchTag }
    }
}
