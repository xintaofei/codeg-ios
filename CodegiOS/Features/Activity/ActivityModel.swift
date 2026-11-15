import Foundation
import Observation

/// App-wide pulse of the selected server: a periodically refreshed snapshot of
/// its folders + conversations, from which the Activity tab, the bottom
/// "running" bar, the sidebar badge, and the Folders tab's running counts are
/// all derived.
///
/// This is the poll-based stand-in for the future persistent-WebSocket hub
/// (M4 in the redesign plan): the consumers are already shaped for live data,
/// only this data source swaps later.
@MainActor
@Observable
final class ActivityModel {
    private(set) var conversations: [ConversationSummary] = []
    /// The full folder set (`list_all_folder_details`) — for by-id lookups
    /// (`folderNames`, a conversation's folder by id, incl. worktree/chat folders).
    private(set) var folders: [FolderDetail] = []
    /// The workspace-visible folder set (`list_open_folder_details`, open+regular).
    /// The Folders tab renders `displayFolders` derived from this; running counts
    /// and per-folder conversation lists merge worktree children into their root.
    private(set) var openFolders: [FolderDetail] = []
    /// Whether `openFolders` has been fetched successfully at least once. Until it
    /// has, the display falls back to the full set; once it has, an empty result is
    /// respected (the server genuinely has no open folders) rather than re-falling
    /// back. Distinguishes a failed open-folders fetch from a legitimately empty one.
    private var openFoldersLoaded = false
    private(set) var lastRefreshed: Date?
    private(set) var error: String?
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false

    /// Monotonic token so a slow fetch can't clobber a newer one's results
    /// (also bumped by `reset()` to invalidate in-flight fetches).
    private var fetchGeneration = 0
    private var loadedEndpoint: String?
    /// ``CodegClient/tagEndpoint`` of the server the rows are from, so a tag
    /// write confirmed on another server patches none of them.
    private var tagEndpoint: String?

    /// Consecutive polls where *both* endpoints failed (after retries). Debounces
    /// the error banner so a single blip in the 25s pulse doesn't flash an error
    /// over an otherwise-fine list; the banner shows only once it persists.
    private var consecutiveFailures = 0
    private static let failuresBeforeAlerting = 2

    /// How many of `conversations` are running — the tab badge. Kept apart
    /// from the list so its readers redraw only when the number changes.
    private(set) var runningCount = 0

    // MARK: - Derived

    /// Sessions currently running, most recently updated first.
    var running: [ConversationSummary] {
        conversations.filter { $0.status.isLive }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Non-running sessions touched in the last 24 hours, most recent first.
    var recent: [ConversationSummary] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return conversations.filter { !$0.status.isLive && $0.updatedAt >= cutoff }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The folder set the display + grouping derive from: the open set normally,
    /// but the FULL set as a fallback when the open-folders endpoint failed while
    /// the full one succeeded — so the Folders tab / grouping degrade to showing
    /// everything (still hiding chat + worktree children) rather than going empty.
    private var displaySource: [FolderDetail] { openFoldersLoaded ? openFolders : folders }

    /// Worktree-child folder id → root id, over `displaySource`. Computed so it
    /// always tracks the rendered folder set (never goes stale vs `conversations`).
    var childToParent: [Int: Int] { FolderVisibility.childToParent(displaySource) }

    /// Folders shown as rows in the Folders tab: open + regular, with worktree
    /// children of an open root hidden (their sessions fold into the root). Sorted
    /// by the view.
    var displayFolders: [FolderDetail] {
        FolderVisibility.visibleFolders(displaySource)
    }

    /// `folderId -> name` lookup for row labels — over the FULL set so a worktree
    /// or chat folder id still resolves.
    var folderNames: [Int: String] {
        Dictionary(folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Running-session count per folder, for the Projects tab's badges. A root
    /// folder's count includes its (hidden) worktree children's running sessions,
    /// matching the web's merged grouping.
    func runningCount(folderID: Int) -> Int {
        conversations.lazy.filter {
            FolderVisibility.mergedFolderId($0.folderId, childToParent: self.childToParent) == folderID
                && $0.status.isLive
        }.count
    }

    /// Conversations in one folder (worktree children merged into the root), most
    /// recent first (Project detail reuses the already-loaded snapshot instead of
    /// refetching).
    func conversations(in folderID: Int) -> [ConversationSummary] {
        conversations.filter {
            FolderVisibility.mergedFolderId($0.folderId, childToParent: childToParent) == folderID
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Lifecycle

    /// Drop everything (server switched / removed). Also invalidates any fetch
    /// still in flight against the old endpoint.
    func reset() {
        fetchGeneration += 1
        conversations = []
        runningCount = 0
        folders = []
        openFolders = []
        openFoldersLoaded = false
        hasLoaded = false
        isRefreshing = false
        error = nil
        lastRefreshed = nil
        loadedEndpoint = nil
        tagEndpoint = nil
        consecutiveFailures = 0
    }

    /// The server confirmed a conversation's tags (a picker's write): patch
    /// the row in place, so its chips don't wait for the next pulse.
    func applyTagChange(_ change: ConversationTagsChange) {
        conversations.applyTagChange(change, endpoint: tagEndpoint)
    }

    /// Clears a surfaced refresh-error banner (a failed refresh over a list that
    /// still has rows). The next refresh also clears it.
    func dismissError() { error = nil }

    /// One fetch against the given client. Endpoint changes clear stale data
    /// first so a slow old server's rows never show under a new server's name.
    func refresh(client: CodegClient?) async {
        guard let client else {
            reset()
            return
        }
        let endpoint = "\(client.baseURL.absoluteString)|\(client.token)"
        if endpoint != loadedEndpoint {
            reset()
            loadedEndpoint = endpoint
            tagEndpoint = client.tagEndpoint
        }
        fetchGeneration += 1
        let token = fetchGeneration
        isRefreshing = true
        defer { if token == fetchGeneration { isRefreshing = false } }

        let result = await client.loadServerSnapshot()
        guard token == fetchGeneration else { return }
        if result.cancelled { return }

        // Partial success: apply whichever endpoint returned, keep the prior value
        // for one that failed (orphaned rows fall into the "Other" safety net).
        adopt(folders: result.folders, openFolders: result.openFolders, conversations: result.conversations)

        if result.anySucceeded {
            hasLoaded = true
            error = nil
            lastRefreshed = Date()
            consecutiveFailures = 0
            // A conversation row can be backed by a user-registered ACP agent, and
            // its name/icon live only on the server. Ride the app-wide pulse so the
            // very first Chats render has them, without a per-row fetch. Once-per-
            // endpoint; a failure leaves the humanized-slug fallback in place.
            await CustomAgentRegistry.shared.refreshIfNeeded(client: client)
        } else {
            // Both failed after retries. Debounce so a lone blip in the periodic
            // pulse stays silent; surface it once it persists (or on first load,
            // where there's nothing on screen yet).
            consecutiveFailures += 1
            if !hasLoaded || consecutiveFailures >= Self.failuresBeforeAlerting {
                error = result.message
            }
        }
    }

    /// Commit one pulse's reads; a nil (a read that failed) keeps the prior
    /// value. The running count is written apart from the list: the list
    /// changes on most pulses (a running conversation's time moves on), the
    /// count rarely — and the app shell, which reads it for the badge,
    /// redraws only when it does.
    func adopt(folders: [FolderDetail]?, openFolders: [FolderDetail]?, conversations: [ConversationSummary]?) {
        if let folders { self.folders = folders }
        if let openFolders { self.openFolders = openFolders; openFoldersLoaded = true }
        if let conversations {
            self.conversations = conversations
            runningCount = conversations.reduce(0) { $0 + ($1.status.isLive ? 1 : 0) }
        }
    }

    /// Long-running refresh loop — run from a SwiftUI `.task(id:)` so it is
    /// cancelled and restarted with the scene phase and server identity.
    func autoRefresh(client: CodegClient?, interval: Duration = .seconds(25)) async {
        while !Task.isCancelled {
            await refresh(client: client)
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }
}
