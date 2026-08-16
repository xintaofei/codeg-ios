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

    /// `true` while the initial full-screen load is in flight (drives the
    /// loader vs. list decision). Refreshes do NOT set this — they keep the
    /// existing list on screen and report progress via `isRefreshing`.
    private(set) var isLoading = false
    /// `true` while a pull-to-refresh / toolbar refresh is in flight.
    private(set) var isRefreshing = false
    /// User-facing error message for the most recent load/refresh/pin, if it failed.
    private(set) var error: String?

    /// Desktop sidebar "Show completed conversations". Default off. Persisted
    /// so iPhone and iPad keep the same choice. Pinned rows ignore this.
    var showCompleted: Bool = SessionListPrefs.showCompleted {
        didSet {
            guard showCompleted != oldValue else { return }
            SessionListPrefs.showCompleted = showCompleted
        }
    }

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
    /// after applying the search filter. Completed pins stay visible (desktop).
    func pinned(searchText: String) -> [ConversationSummary] {
        matching(conversations.filter(\.isPinned), searchText)
            .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
    }

    /// Completed conversations currently hidden by the default filter. Used
    /// to tell "no sessions at all" from "only finished ones, flip the toggle".
    var hiddenCompletedCount: Int {
        guard !showCompleted else { return 0 }
        return conversations.filter { $0.status == .completed && !$0.isPinned }.count
    }

    /// Search hits that exist only among hidden completed rows.
    func hasHiddenCompletedMatches(searchText: String) -> Bool {
        guard !showCompleted else { return false }
        let hidden = conversations.filter { $0.status == .completed && !$0.isPinned }
        return !matching(hidden, searchText).isEmpty
    }

    /// One group per folder (in `sortedFolders` order) holding that folder's
    /// non-pinned conversations, newest-first. With no search every folder is
    /// included — even empty ones, so their collapsible header still shows; when
    /// searching, folders with no matching conversation are dropped.
    func folderGroups(searchText: String) -> [FolderGroup] {
        let searching = !trimmed(searchText).isEmpty
        // Group by the merge target so a worktree's conversations land under its
        // root folder's header (matching the web), not a hidden worktree row.
        let map = childToParent
        let unpinnedByGroup = Dictionary(grouping: visibleUnpinned) {
            FolderVisibility.mergedFolderId($0.folderId, childToParent: map)
        }
        return sortedFolders.compactMap { folder in
            let convs = matching(unpinnedByGroup[folder.id] ?? [], searchText)
                .sorted { $0.updatedAt > $1.updatedAt }
            if searching, convs.isEmpty { return nil }
            return FolderGroup(folder: folder, conversations: convs)
        }
    }

    /// Non-pinned conversations whose (merged) folder isn't a visible group —
    /// orphans / chat-folder sessions — shown in a trailing "Other" group.
    /// Newest-first, search-filtered. Normally empty: a safety net so a
    /// conversation never silently disappears.
    func ungrouped(searchText: String) -> [ConversationSummary] {
        let map = childToParent
        let known = Set(sortedFolders.map(\.id))
        return matching(visibleUnpinned.filter {
            !known.contains(FolderVisibility.mergedFolderId($0.folderId, childToParent: map))
        }, searchText)
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Non-pinned conversations after the completed filter.
    private var visibleUnpinned: [ConversationSummary] {
        SessionListVisibility.filter(
            conversations.filter { !$0.isPinned },
            showCompleted: showCompleted
        )
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Filter a slice of conversations by the search query (title / model).
    private func matching(_ convs: [ConversationSummary], _ searchText: String) -> [ConversationSummary] {
        let query = trimmed(searchText)
        guard !query.isEmpty else { return convs }
        return convs.filter { conv in
            if conv.displayTitle.localizedCaseInsensitiveContains(query) { return true }
            if let model = conv.model, model.localizedCaseInsensitiveContains(query) { return true }
            return false
        }
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
        // fails the whole refresh.
        let result = await client.loadServerSnapshot()

        // A newer fetch superseded this one, or the view went away — discard.
        guard token == fetchGeneration else { return }
        if result.cancelled { return }

        // Partial success degrades gracefully: apply whichever endpoint returned,
        // and keep the prior value for one that failed.
        if let loaded = result.folders { folders = loaded }
        if let loaded = result.openFolders { openFolders = loaded; openFoldersLoaded = true }
        if let loaded = result.conversations { conversations = loaded }

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
}
