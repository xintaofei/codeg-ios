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
    /// refuses any other), not chat folders, less the one it sits in now.
    /// Worktrees are ordinary destinations, as on the web.
    static func targets(open: [FolderDetail], currentFolderID: Int) -> [FolderDetail] {
        open.filter { $0.kind != .chat && $0.id != currentFolderID }
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
}
