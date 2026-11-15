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
        guard conversation.canCarryTags else { return .none }
        let branch = ConversationTags.branchChip(for: conversation, enabled: branchTag.enabled)
        let resolved = ConversationTags.resolve(conversation.tagIds, in: tagsByID)
        guard branch != nil || !resolved.isEmpty else { return .none }
        return RowTags(tags: resolved, branch: branch, branchColor: branchTag.color)
    }

    /// The server confirmed a conversation's tags (a picker's write): patch the
    /// row in place. A refetch per toggle could land behind the next toggle.
    func applyTagChange(_ change: ConversationTagsChange) {
        guard change.endpoint == client.tagEndpoint,
              let index = conversations.firstIndex(where: { $0.id == change.conversationID }) else { return }
        conversations[index].tagIds = change.tagIDs
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
        self.client = client
        loadedEndpoint = endpoint
        await fetch(isInitial: true, force: endpointChanged)
    }

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
        if let conversations { self.conversations = conversations }
        if let tags { self.tags = tags }
        if let branchTag { self.branchTag = branchTag }
    }
}
