import SwiftUI

/// A project/workspace on a codeg server (Rust `FolderDetail`). The iOS app
/// treats folders as a filter dimension under a server, and uses `path` as the
/// `workingDir` when (re)connecting an agent.
struct FolderDetail: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let path: String
    let gitBranch: String?
    let defaultAgentType: AgentType?
    let lastOpenedAt: Date
    let sortOrder: Int
    let color: String
    /// Root folder this one was created under (worktree folders only); `nil` for
    /// a top-level folder. Drives the sidebar worktree-child hide and the branch
    /// switcher's root resolution. Decoded from `parent_id`; absent on older
    /// servers → `nil`.
    var parentId: Int?
    /// Server `kind`. `chat` scratch folders are hidden from the folder lists;
    /// `regular` is a user folder. Absent / unknown on older servers → `.regular`.
    var kind: FolderKind

    private enum CodingKeys: String, CodingKey {
        case id, name, path, gitBranch, defaultAgentType, lastOpenedAt, sortOrder, color, parentId, kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        defaultAgentType = try c.decodeIfPresent(AgentType.self, forKey: .defaultAgentType)
        lastOpenedAt = try c.decode(Date.self, forKey: .lastOpenedAt)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        color = try c.decode(String.self, forKey: .color)
        parentId = try c.decodeIfPresent(Int.self, forKey: .parentId)
        // Tolerate an absent key (older server) and an unknown value (lenient
        // `FolderKind` decode) — neither should fail the whole folder.
        kind = (try? c.decodeIfPresent(FolderKind.self, forKey: .kind)) ?? .regular
    }

    /// Memberwise initializer (preserved for the few call sites that build a
    /// `FolderDetail` directly, e.g. previews/tests).
    init(
        id: Int, name: String, path: String, gitBranch: String?,
        defaultAgentType: AgentType?, lastOpenedAt: Date, sortOrder: Int,
        color: String, parentId: Int? = nil, kind: FolderKind = .regular
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.gitBranch = gitBranch
        self.defaultAgentType = defaultAgentType
        self.lastOpenedAt = lastOpenedAt
        self.sortOrder = sortOrder
        self.color = color
        self.parentId = parentId
        self.kind = kind
    }

    /// True when this folder is a git worktree created under another folder.
    var isWorktree: Bool { parentId != nil }
}

/// Folder classification (Rust `FolderKind`). `chat` folders back chat-mode
/// scratch dirs and are hidden from folder lists; `regular` is a user folder.
/// `.other` is the escape hatch for an unknown wire value.
enum FolderKind: String, Codable, Hashable, Sendable {
    case regular
    case chat
    case other = ""

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FolderKind(rawValue: raw) ?? .other
    }
}

/// Conversation classification (Rust `ConversationKind`): what a row is for,
/// which decides where it lists and whether it may move. `.other` is the escape
/// hatch for an unknown wire value, so one new kind can't fail a whole list.
enum ConversationKind: String, Codable, Hashable, Sendable {
    case regular
    case chat
    case loop
    case delegate
    case other = ""

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConversationKind(rawValue: raw) ?? .other
    }
}

/// Lifecycle status of a conversation row. Stored as a free-form string on the
/// wire; modeled as an enum with an `.other` escape hatch.
enum ConversationStatus: String, Codable, Hashable, Sendable {
    case inProgress = "in_progress"
    case pendingReview = "pending_review"
    case completed = "completed"
    case cancelled = "cancelled"
    case other = ""

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConversationStatus(rawValue: raw) ?? .other
    }

    var label: LocalizedStringKey {
        switch self {
        case .inProgress: return "Running"
        case .pendingReview: return "Review"
        case .completed: return "Done"
        case .cancelled: return "Cancelled"
        case .other: return "—"
        }
    }

    var tint: Color {
        switch self {
        case .inProgress: return Color(red: 0.42, green: 0.78, blue: 0.95)
        case .pendingReview: return Theme.warning
        case .completed: return Color(red: 0.52, green: 0.82, blue: 0.56)
        case .cancelled: return Color.secondary
        case .other: return Color.secondary
        }
    }

    var isLive: Bool { self == .inProgress }

    /// The real statuses a user can assign from the actions menu (excludes the
    /// `.other` decode escape hatch), in the order the web client lists them.
    static let selectable: [ConversationStatus] = [.inProgress, .pendingReview, .completed, .cancelled]
}

/// Posted (no payload) whenever a conversation is mutated from the detail
/// screen — renamed, pinned, status-changed, or deleted. The session list is a
/// separate view model with no `onAppear` reload, so it observes this to refetch
/// instead of showing a stale title/status or a still-tappable deleted row.
extension Notification.Name {
    static let conversationsDidChange = Notification.Name("codeg.conversationsDidChange")
    /// Posted (no payload) when the folder set changes outside the normal poll —
    /// e.g. a worktree folder was just registered from the branch switcher. Folder-
    /// backed lists (Folders tab, Chats grouping) observe it to refetch promptly
    /// instead of waiting for the 25s pulse.
    static let foldersDidChange = Notification.Name("codeg.foldersDidChange")
    /// Posted when the server confirmed a conversation's tags, with a
    /// ``ConversationTagsChange`` as the object. Screens holding that row patch
    /// it in place — a full refetch per toggle could land behind the next one
    /// and draw it stale.
    static let conversationTagsDidChange = Notification.Name("codeg.conversationTagsDidChange")
    /// Posted (no payload) when a tag was created, renamed, recoloured,
    /// reordered or deleted, or the branch tag setting changed: lists re-read
    /// the tag definitions their chips resolve against.
    static let conversationTagDefinitionsDidChange = Notification.Name("codeg.conversationTagDefinitionsDidChange")
}

/// A conversation/session persisted on a server (Rust `DbConversationSummary`).
struct ConversationSummary: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    /// `var` so a move made from the session screen re-points it at once (the
    /// re-read that follows brings the rest of the row).
    var folderId: Int
    /// `var` so the detail screen can optimistically reflect a rename before the
    /// server confirms (mirrors `pinnedAt`).
    var title: String?
    let agentType: AgentType
    /// `var` so a status change applies optimistically from the actions menu.
    var status: ConversationStatus
    let model: String?
    let gitBranch: String?
    /// `var` so a fork can re-point it the moment the backend confirms, before
    /// the re-read lands: every reconnect resumes this session id, and after a
    /// fork the old one belongs to the sibling row.
    var externalId: String?
    let messageCount: Int
    let createdAt: Date
    let updatedAt: Date
    /// When the user pinned this conversation (server `pinned_at`), or `nil` when
    /// not pinned. The default makes the key optional during decode, so servers
    /// that predate pinning (no field) decode cleanly to `nil`. A `var` so the
    /// list can optimistically flip it on a pin/unpin before the server confirms.
    /// Note: pinning does NOT bump `updatedAt` server-side — the "Pinned" group
    /// sorts by this timestamp instead.
    var pinnedAt: Date? = nil
    /// Server `kind`: `regular`, `chat`, `loop` or `delegate`. Absent (nil) on
    /// a server that predates it, which only matters for what may move.
    var kind: ConversationKind? = nil
    /// The delegating conversation, on a delegation child (a sub-session);
    /// absent on a root row.
    var parentId: Int? = nil
    /// `tag_ids` as it arrived: the server leaves the key out when there are
    /// none, so it decodes optional and ``tagIds`` reads it as an array.
    private var wireTagIds: [Int]? = nil

    private enum CodingKeys: String, CodingKey {
        case id, folderId, title, agentType, status, model, gitBranch, externalId
        case messageCount, createdAt, updatedAt, pinnedAt, kind, parentId
        // `.convertFromSnakeCase` has already turned `tag_ids` into this.
        case wireTagIds = "tagIds"
    }

    /// The tags on this conversation, ascending. May still name a tag deleted
    /// since — the server does not re-send every row when a tag goes — so
    /// readers resolve it against the tag list and skip what it lacks. A `var`
    /// so a tag edit can patch the row before the next refetch.
    var tagIds: [Int] {
        get { wireTagIds ?? [] }
        set { wireTagIds = newValue.isEmpty ? nil : newValue }
    }

    /// Whether it may be moved to another folder (`move_conversations`): a root
    /// conversation, regular or chat (web `sidebar-conversation-card`). A
    /// sub-session moves with its parent and a loop never moves. A server that
    /// sends no kind leaves a root row movable — it judges each move anyway.
    var isMovable: Bool {
        guard parentId == nil else { return false }
        switch kind {
        case nil, .regular?, .chat?: return true
        default: return false
        }
    }

    /// Whether it carries tags of its own: root rows only. A sub-session is a
    /// sub-agent's run, not a conversation the user files away (web
    /// `isSubsession`), so it gets neither tags nor a branch chip.
    var canCarryTags: Bool { parentId == nil }

    /// Non-empty, trimmed user-provided title, or `nil` for an unnamed session.
    /// Render this verbatim (user data, never localized) and fall back to a
    /// localized "Untitled session" only when it is `nil`.
    var trimmedTitle: String? {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return title
    }

    /// Plain-text title for search/filtering (NOT for localized display — use
    /// `trimmedTitle` + a literal fallback at the render site for that).
    var displayTitle: String { trimmedTitle ?? "Untitled session" }

    var isPinned: Bool { pinnedAt != nil }
}

/// Aggregate token/timing stats for a session (Rust `SessionStats`).
struct SessionStats: Codable, Hashable, Sendable {
    let totalUsage: TurnUsage?
    let totalTokens: Int?
    let totalDurationMs: Int
    let contextWindowUsedTokens: Int?
    let contextWindowMaxTokens: Int?
    let contextWindowUsagePercent: Double?
}

/// Full session detail incl. message history (Rust `DbConversationDetail`).
/// Decode-only: `MessageTurn`/`ContentBlock` are response shapes we never encode.
///
/// When the request asked for a turn window (`tailTurns` / `fromIndex`), `turns`
/// holds only `full[turnsOffset...]` and the four window fields below describe
/// where that slice sits. **Every other field still describes the FULL
/// transcript** — `summary`'s counts, `sessionStats`, `inFlightUserTurnId`.
struct ConversationDetail: Decodable, Sendable {
    let summary: ConversationSummary
    let turns: [MessageTurn]
    let sessionStats: SessionStats?
    let inFlightUserTurnId: String?

    /// Global index of `turns[0]`. Absent on a server that predates windowing
    /// (≤ 0.23), which always answers with the whole transcript.
    let turnsOffset: Int?
    /// Turn count of the full transcript.
    let turnsTotal: Int?
    /// Server fingerprint of `full[0..<turnsOffset)`, fixed-width 16-hex. Compared
    /// verbatim — we never compute one locally, so its construction (FNV-1a over
    /// role + timestamp-millis) is the server's business.
    let prefixHash: String?
    /// User turns in `full[0..<turnsOffset)` — what the message navigator
    /// numbers the loaded messages on from. Absent from a server that predates
    /// the outline route (≤ 0.35) and from a legacy full response, which is
    /// also how the navigator knows not to ask for an outline.
    let userTurnsBeforeOffset: Int?
    /// Byte offset of the agent's transcript this read was parsed through: an
    /// out-of-turn overlay turn read at or before it is in `turns` now
    /// (`background_activity`'s watermark).
    var transcriptWatermark: Int64? = nil
    /// The newest timestamp above the window (`full[0..<turnsOffset)`),
    /// verbatim; absent when the window covers everything. What a windowed
    /// read can prove it covers of the overlay.
    var uncoveredPrefixMaxTs: String? = nil

    var uncoveredPrefixMaxDate: Date? { uncoveredPrefixMaxTs.flatMap(ISO8601.parse) }

    /// Global index one past the last loaded turn. The coordinate to compare
    /// against when asking "did the transcript advance past what I hold?" — the
    /// loaded `turns.count` alone stops growing once a tail window is saturated,
    /// and drops outright when a window resets.
    var globalEnd: Int { (turnsOffset ?? 0) + turns.count }
}

/// Where a loaded slice of `turns` sits inside the full transcript, for a server
/// that speaks the windowing protocol. `nil`-initialized from a legacy response,
/// which the view model treats as "the whole transcript is loaded".
///
/// iOS deliberately carries only three of the six protocol fields:
/// `assistant_turns_before_offset` globalizes a send-time assistant baseline the
/// web needs for its turn-metadata patch pass, and `uncovered_prefix_max_ts`
/// gates its background-overlay retirement — neither mechanism exists here. And
/// the client-side fingerprint *extension* the web performs is likewise only for
/// that patch gate; we compare server-issued hashes and never derive one.
struct TranscriptWindow: Equatable, Sendable {
    /// Global index of the first loaded turn.
    var offset: Int
    /// Turn count of the full transcript.
    var total: Int
    /// Fingerprint of the not-yet-loaded prefix `full[0..<offset)`.
    var prefixHash: String
    /// User turns in `full[0..<offset)` (`user_turns_before_offset`); nil from
    /// a server without the outline route. Rides with the window because it is
    /// one more fact about the same coordinates: every adoption of a window
    /// brings its own.
    var userTurnsBefore: Int? = nil

    /// Present only when the response carried all three fields; their absence
    /// means a legacy full response and every windowed path must stand down.
    init?(_ detail: ConversationDetail) {
        guard let offset = detail.turnsOffset,
              let total = detail.turnsTotal,
              let prefixHash = detail.prefixHash
        else { return nil }
        self.init(offset: offset, total: total, prefixHash: prefixHash)
        userTurnsBefore = detail.userTurnsBeforeOffset
    }

    init(offset: Int, total: Int, prefixHash: String) {
        self.offset = offset
        self.total = total
        self.prefixHash = prefixHash
    }

    /// Older history exists above the loaded slice.
    var hasOlder: Bool { offset > 0 }
}

/// One page of older history (`get_folder_conversation_turns`), covering
/// `full[turnsOffset ..< turnsOffset + turns.count]` and ending just before the
/// `beforeIndex` that was asked for. A light response: history only, no summary,
/// no stats, no live correlation.
struct ConversationTurnsPage: Decodable, Sendable {
    let turns: [MessageTurn]
    let turnsOffset: Int
    let turnsTotal: Int
    /// Fingerprint of `full[0..<turnsOffset)` — adopted as the window's new
    /// prefix hash once the page is prepended.
    let prefixHash: String
    /// Fingerprint of `full[0..<beforeIndex)` — the **seam proof**. It must equal
    /// the window's current prefix hash, or this page came from a parse whose
    /// prefix was rewritten since and cannot legally join what is loaded.
    let prefixHashBeforeIndex: String
    /// User turns in `full[0..<turnsOffset)` — the window's new count once the
    /// page is prepended. Optional: a server without the outline route
    /// (≤ 0.35) omits it, and paging must go on working against one.
    let userTurnsBeforeOffset: Int?
}

/// Returned by `acp_find_connection_for_conversation` when a live ACP
/// connection already owns a conversation.
struct ConversationConnectionInfo: Codable, Sendable {
    let connectionId: String
    let eventSeq: UInt64
}

/// `health` endpoint response — used to validate a server profile.
struct HealthResponse: Codable, Sendable {
    let status: String
    let version: String
}
