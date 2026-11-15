import Foundation

/// Body for `move_conversations`. camelCase, encoded as-is.
struct MoveConversationsBody: Encodable, Sendable {
    let conversationIds: [Int]
    let targetFolderId: Int
}

/// Why `move_conversations` left a conversation where it was (Rust
/// `MoveSkipReason`, snake_case values). `.other` keeps a reason this client
/// doesn't know yet, so a new one can't fail the whole answer.
enum MoveSkipReason: Equatable, Sendable, Decodable {
    case notFound
    case notMovable
    case alreadyThere
    case taskOwned
    case busy
    case conflict
    case targetUnavailable
    case other(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "not_found": self = .notFound
        case "not_movable": self = .notMovable
        case "already_there": self = .alreadyThere
        case "task_owned": self = .taskOwned
        case "busy": self = .busy
        case "conflict": self = .conflict
        case "target_unavailable": self = .targetUnavailable
        default: self = .other(raw)
        }
    }

    /// The reason, as the web words it.
    var message: String {
        switch self {
        case .notFound: return String(localized: "It no longer exists")
        case .notMovable: return String(localized: "Sub-conversations move with their parent")
        case .alreadyThere: return String(localized: "It is already in this folder")
        case .taskOwned: return String(localized: "It belongs to a to-do task")
        case .busy: return String(localized: "An agent is working on it — try again when it's done")
        case .conflict: return String(localized: "It changed while being moved — try again")
        case .targetUnavailable: return String(localized: "The folder was closed or removed")
        case .other: return String(localized: "For a reason this app doesn't know")
        }
    }
}

/// One conversation the move left behind, and why.
struct MoveConversationSkip: Decodable, Equatable, Sendable {
    let conversationId: Int
    let reason: MoveSkipReason
}

/// What `move_conversations` did (Rust `MoveConversationsResult`). Serialized
/// **camelCase** by the backend (`#[serde(rename_all = "camelCase")]`), like
/// `acp_fork`'s answer — `.convertFromSnakeCase` leaves keys without
/// underscores alone, so the shared decoder reads it as-is.
struct MoveConversationsResult: Decodable, Equatable, Sendable {
    /// Root conversations moved; their delegation children went with them.
    let moved: [Int]
    let skipped: [MoveConversationSkip]

    init(moved: [Int], skipped: [MoveConversationSkip]) {
        self.moved = moved
        self.skipped = skipped
    }

    private enum CodingKeys: String, CodingKey { case moved, skipped }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        moved = try c.decodeIfPresent([Int].self, forKey: .moved) ?? []
        skipped = try c.decodeIfPresent([MoveConversationSkip].self, forKey: .skipped) ?? []
    }
}

/// What ``Notification.Name.conversationDidMove`` carries: a conversation the
/// Chats list moved, and where to. A session screen open on it (the iPad
/// split) lets go of the old folder's connection before its next send.
struct ConversationMovedChange: Sendable {
    /// The server's base URL — ids are a server's own.
    let endpoint: String
    let conversationID: Int
    let folderID: Int
}

extension Notification.Name {
    /// Posted by the Chats list after the server confirmed a move, with a
    /// ``ConversationMovedChange`` as the object.
    static let conversationDidMove = Notification.Name("codeg.conversationDidMove")
}

/// The rules of "Move to…" (web `move-conversation-dialog` /
/// `move-to-folder-menu`). Pure, for tests.
enum ConversationMove {
    /// What one move came to for the conversation it was asked about.
    enum Outcome: Equatable {
        case moved
        case skipped(MoveSkipReason)
        /// The answer named it in neither list (a server this client
        /// doesn't understand).
        case unknown
    }

    /// The folders a move may land in: the server's OPEN folders (the server
    /// refuses any other), not chat folders, less the one the conversations
    /// sit in now when they share one (nil: they don't, so none is left out —
    /// the server skips each one already there). Worktrees are ordinary
    /// destinations, as on the web.
    static func targets(open: [FolderDetail], currentFolderID: Int?) -> [FolderDetail] {
        open.filter { $0.kind != .chat && $0.id != currentFolderID }
    }

    /// The one folder every conversation is in, or nil when they differ (web
    /// `sharedFolderId`).
    static func sharedFolderID(_ conversations: [ConversationSummary]) -> Int? {
        guard let first = conversations.first?.folderId else { return nil }
        return conversations.allSatisfy { $0.folderId == first } ? first : nil
    }

    /// A folder as a move names it: a worktree reads as its repo and branch —
    /// its own name is usually a generated directory.
    static func label(for folder: FolderDetail, in all: [FolderDetail]) -> String {
        let name = FolderVisibility.displayName(of: folder, in: all)
        if folder.isWorktree, let branch = folder.gitBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
           !branch.isEmpty {
            return "\(name) · \(branch)"
        }
        return name
    }

    static func outcome(of result: MoveConversationsResult, for conversationID: Int) -> Outcome {
        if result.moved.contains(conversationID) { return .moved }
        if let skip = result.skipped.first(where: { $0.conversationId == conversationID }) {
            return .skipped(skip.reason)
        }
        return .unknown
    }

    /// The one line a move's outcome is told in (nil when there is nothing to
    /// say). One conversation at a time here, so no counts.
    static func message(for result: MoveConversationsResult, conversationID: Int, folderName: String) -> String? {
        switch outcome(of: result, for: conversationID) {
        case .moved: return String(localized: "Moved to \(folderName)")
        case .skipped(let reason): return String(localized: "Not moved: \(reason.message)")
        case .unknown: return nil
        }
    }

    /// A failed request's line.
    static func failure(_ error: Error) -> String {
        let reason: String
        if let api = error as? APIError { reason = api.errorDescription ?? "\(api)" } else { reason = error.localizedDescription }
        return String(localized: "Couldn't move: \(reason)")
    }

    // MARK: - Several at once

    /// What a move of several conversations came to, over the ones asked about.
    struct BatchOutcome: Equatable {
        /// Asked about and moved, in the order asked.
        let moved: [Int]
        /// Asked about and left where they were — skipped, or named in neither
        /// list — in the order asked.
        let notMoved: [Int]
        /// Why they were left, each reason said once, in the order first met.
        let reasons: [String]

        var movedAll: Bool { notMoved.isEmpty }
    }

    static func batchOutcome(of result: MoveConversationsResult, requested: [Int]) -> BatchOutcome {
        var seen = Set<Int>()
        let asked = requested.filter { seen.insert($0).inserted }
        let movedIDs = Set(result.moved)
        let notMoved = asked.filter { !movedIDs.contains($0) }
        var reasons: [String] = []
        for id in notMoved {
            guard let skip = result.skipped.first(where: { $0.conversationId == id }) else { continue }
            let reason = skip.reason.message
            if !reasons.contains(reason) { reasons.append(reason) }
        }
        return BatchOutcome(moved: asked.filter(movedIDs.contains), notMoved: notMoved, reasons: reasons)
    }

    /// What a move of `requested` is told in (web `toastMoved` + `toastSkipped`):
    /// how many moved, then — on a line of its own — how many didn't and why.
    /// One conversation reads as ``message(for:conversationID:folderName:)``.
    static func batchMessage(for result: MoveConversationsResult, requested: [Int], folderName: String) -> String? {
        let outcome = batchOutcome(of: result, requested: requested)
        let asked = outcome.moved + outcome.notMoved
        if asked.count == 1, let only = asked.first {
            return message(for: result, conversationID: only, folderName: folderName)
        }
        var lines: [String] = []
        switch outcome.moved.count {
        case 0: break
        case 1: lines.append(String(localized: "Moved 1 conversation to \(folderName)"))
        case let count: lines.append(String(localized: "Moved \(count) conversations to \(folderName)"))
        }
        if !outcome.notMoved.isEmpty {
            let count = outcome.notMoved.count
            let why = outcome.reasons.joined(separator: " · ")
            switch (count == 1, why.isEmpty) {
            case (true, true): lines.append(String(localized: "1 conversation was not moved"))
            case (true, false): lines.append(String(localized: "1 conversation was not moved: \(why)"))
            case (false, true): lines.append(String(localized: "\(count) conversations were not moved"))
            case (false, false): lines.append(String(localized: "\(count) conversations were not moved: \(why)"))
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// The Chats list's selection mode (web Manage conversations' checkboxes):
/// the conversations picked for one "Move to…". Only a conversation that may
/// move can be picked. A pick outlives a search or a tag filter that hides its
/// row, and a refetch while its row is still there; after a move, what moved
/// is let go and what was left behind stays picked for another go. Pure, for
/// tests.
struct ConversationSelection: Equatable, Sendable {
    private(set) var ids: Set<Int> = []

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: Int) -> Bool { ids.contains(id) }

    /// Whether `conversation` can be picked: one that may move.
    static func canPick(_ conversation: ConversationSummary) -> Bool { conversation.isMovable }

    /// Take what the list's own selection hands back (a tap, a swipe across
    /// rows): only conversations of `conversations` that may move.
    mutating func set(_ picked: Set<Int>, among conversations: [ConversationSummary]) {
        ids = picked.intersection(Self.pickable(conversations))
    }

    mutating func toggle(_ conversation: ConversationSummary) {
        guard Self.canPick(conversation) else { return }
        if ids.contains(conversation.id) { ids.remove(conversation.id) } else { ids.insert(conversation.id) }
    }

    /// Every pickable one of `visible` is picked — false when none is.
    func coversAll(_ visible: [ConversationSummary]) -> Bool {
        let pickable = Self.pickable(visible)
        return !pickable.isEmpty && pickable.isSubset(of: ids)
    }

    /// Select All over the rows on screen — or, when they are all picked
    /// already, Deselect All of them. Picks whose rows are hidden stay as they
    /// are.
    mutating func toggleAll(_ visible: [ConversationSummary]) {
        let pickable = Self.pickable(visible)
        if !pickable.isEmpty, pickable.isSubset(of: ids) { ids.subtract(pickable) } else { ids.formUnion(pickable) }
    }

    /// Keep only what is still listed and may still move (after a refetch).
    mutating func prune(to conversations: [ConversationSummary]) {
        let kept = ids.intersection(Self.pickable(conversations))
        if kept != ids { ids = kept }
    }

    /// The picked conversations, in `conversations`' order.
    func picked(from conversations: [ConversationSummary]) -> [ConversationSummary] {
        conversations.filter { ids.contains($0.id) && Self.canPick($0) }
    }

    /// A move ran: what it moved is let go; the rest stays picked.
    mutating func settle(_ result: MoveConversationsResult) {
        ids.subtract(result.moved)
    }

    private static func pickable(_ conversations: [ConversationSummary]) -> Set<Int> {
        Set(conversations.lazy.filter(canPick).map(\.id))
    }
}
