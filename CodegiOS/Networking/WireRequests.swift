import Foundation

/// A block of a prompt sent to an agent (Rust `PromptInputBlock`, tagged by
/// `type`). Encode-only. The request encoder does NOT convert keys, so the
/// snake_case wire keys (`mime_type`) are spelled explicitly here.
enum PromptInputBlock: Encodable, Sendable {
    case text(String)
    case image(data: String, mimeType: String, uri: String?)
    case resourceLink(uri: String, name: String, mimeType: String?)

    private enum CodingKeys: String, CodingKey {
        case type, text, data, name
        case mimeType = "mime_type"
        case uri
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .image(let data, let mimeType, let uri):
            try c.encode("image", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(mimeType, forKey: .mimeType)
            try c.encodeIfPresent(uri, forKey: .uri)
        case .resourceLink(let uri, let name, let mimeType):
            try c.encode("resource_link", forKey: .type)
            try c.encode(uri, forKey: .uri)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(mimeType, forKey: .mimeType)
        }
    }
}

// MARK: - Request bodies (camelCase keys; nil optionals are omitted)

struct EmptyBody: Encodable, Sendable {}

struct ListConversationsBody: Encodable, Sendable {
    var folderIds: [Int]?
    var agentType: String?
    var search: String?
    var sortBy: String?
    var status: String?
    var includeChildren: Bool?
}

struct ConversationIdBody: Encodable, Sendable {
    let conversationId: Int
}

struct PutComposerDraftBody: Encodable, Sendable {
    let conversationId: Int
    let text: String
    let origin: String
    var attachments: [ComposerDraftAttachment]?
}

struct ReadUploadAttachmentBody: Encodable, Sendable {
    let path: String
}

struct ReadUploadAttachmentResult: Decodable, Sendable {
    let data: String
    let name: String
    let size: UInt64
    let mimeType: String?
}

struct UploadAttachmentResult: Decodable, Sendable {
    let path: String
    let name: String
    let size: UInt64
    let mimeType: String?
}

/// Body for `create_conversation` — creates a server-side conversation row in
/// `folderId` for `agentType` (optional `title`) BEFORE the first prompt, so the
/// server broadcasts a `conversation_upsert` to every client (the desktop/web
/// sidebars then show it immediately). Mirrors the web client's new-tab flow.
/// Returns the new conversation id. camelCase keys, encoded as-is.
struct CreateConversationBody: Encodable, Sendable {
    let folderId: Int
    let agentType: AgentType
    var title: String?
}

/// Body for `acp_find_connection_for_conversation`. The server requires
/// `agentType` (no default) and accepts an optional `sessionId` (`external_id`)
/// used to match a connection in the pre-first-prompt window.
struct FindConnectionBody: Encodable, Sendable {
    let conversationId: Int
    var sessionId: String?
    let agentType: AgentType
}

struct ConnectBody: Encodable, Sendable {
    let agentType: AgentType
    var workingDir: String?
    var sessionId: String?
    /// Last-used mode/config to start the session with (server applies before
    /// reporting state). Omitted when nil. See `SelectorPrefsStore`.
    var preferredModeId: String?
    var preferredConfigValues: [String: String]?
}

struct PromptBody: Encodable, Sendable {
    let connectionId: String
    let blocks: [PromptInputBlock]
    var folderId: Int?
    var conversationId: Int?
    var clientMessageId: String?
}

struct ConnectionIdBody: Encodable, Sendable {
    let connectionId: String
}

/// Body for `acp_respond_permission` — resolves a `permission_request` (and
/// ExitPlanMode) by selecting one of the offered options. `optionId` is the
/// chosen `PermissionOption.optionId`; a `reject*`-kind option denies.
struct RespondPermissionBody: Encodable, Sendable {
    let connectionId: String
    let requestId: String
    let optionId: String
}

/// Body for `acp_answer_question` — answers an `ask_user_question`. `answer`
/// carries one `QuestionAnswerItem` per question (selected option labels), or
/// `declined: true` with no answers to dismiss.
struct AnswerQuestionBody: Encodable, Sendable {
    let connectionId: String
    let questionId: String
    let answer: QuestionAnswer
}

/// Body for `acp_answer_plan_approval` — resolves Grok's blocked
/// `exit_plan_mode`. `feedback` carries the revision notes for a
/// `request_changes` decision (ignored by the other two).
struct AnswerPlanApprovalBody: Encodable, Sendable {
    let connectionId: String
    let approvalId: String
    let answer: PlanApprovalAnswer
}

struct PlanApprovalAnswer: Encodable, Sendable {
    let decision: PlanApprovalDecision
    var feedback: String?
}

/// Body for `acp_describe_agent_options`. Takes the agent type + an optional
/// working dir — NOT a connection id (the server spawns a throwaway probe agent
/// to enumerate options). camelCase keys, encoded as-is.
struct DescribeAgentOptionsBody: Encodable, Sendable {
    let agentType: AgentType
    var workingDir: String?
}

/// Body for `experts_list_for_agent` — the agent whose linked experts to list.
/// camelCase key (`agentType`), encoded as-is.
struct AgentTypeBody: Encodable, Sendable {
    let agentType: AgentType
}

/// Body for `acp_set_mode` — applies to a live chat `connectionId`.
struct SetModeBody: Encodable, Sendable {
    let connectionId: String
    let modeId: String
}

/// Body for `acp_set_config_option` — applies to a live chat `connectionId`.
struct SetConfigOptionBody: Encodable, Sendable {
    let connectionId: String
    let configId: String
    let valueId: String
}

/// Body for `update_conversation_pinned` — pins (`true`) or unpins (`false`) a
/// conversation. The server sets/clears `pinned_at` and leaves `updated_at`
/// untouched.
struct UpdateConversationPinnedBody: Encodable, Sendable {
    let conversationId: Int
    let pinned: Bool
}

/// Body for `update_conversation_title` — renames a conversation. The server
/// stores the new `title`; the response is `null`.
struct UpdateConversationTitleBody: Encodable, Sendable {
    let conversationId: Int
    let title: String
}

/// Body for `update_conversation_status` — sets the lifecycle status. `status`
/// is the raw wire value (`in_progress` / `pending_review` / `completed` /
/// `cancelled`); the response is `null`.
struct UpdateConversationStatusBody: Encodable, Sendable {
    let conversationId: Int
    let status: String
}

/// Body for endpoints that take a single absolute server-side `path`:
/// `open_folder` and `list_directory_entries`.
struct PathBody: Encodable, Sendable {
    let path: String
}

/// Git auth for `clone_repository` of a private repo (Rust `GitCredentials`).
/// Omitted entirely for public repos.
struct GitCredentials: Encodable, Sendable {
    let username: String
    let password: String
}

/// Body for `clone_repository` — clone `url` into `targetDir` (the full
/// destination path) on the server. `credentials` is omitted for public repos.
struct CloneRepositoryBody: Encodable, Sendable {
    let url: String
    let targetDir: String
    var credentials: GitCredentials?
}

/// Error envelope returned by the server on non-2xx (`{code, message}`).
struct ServerError: Decodable, Sendable {
    let code: String?
    let message: String?
}
