import Foundation

/// Status of a live ACP connection (Rust `ConnectionStatus`).
enum ConnectionStatus: String, Codable, Hashable, Sendable {
    case connecting
    case connected
    case prompting
    case disconnected
    case error

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConnectionStatus(rawValue: raw) ?? .error
    }
}

/// A block of a user's submitted prompt as echoed on the connection stream
/// (Rust `UserMessageBlock`).
enum UserMessageBlock: Hashable, Sendable, Decodable {
    case text(String)
    case image(ImageData)
    case unknown

    private enum CodingKeys: String, CodingKey { case type, text, data, mimeType }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "image":
            self = .image(ImageData(
                data: try c.decodeIfPresent(String.self, forKey: .data) ?? "",
                mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "image/png",
                uri: nil
            ))
        default:
            self = .unknown
        }
    }
}

/// A backend→client ACP event (Rust `AcpEvent`, internally tagged `type`).
/// Decode-only. Unknown event types decode to `.unknown` so a new server event
/// never breaks the stream.
enum AcpEvent: Hashable, Sendable, Decodable {
    case contentDelta(text: String)
    case thinking(text: String)
    case toolCall(id: String, title: String, kind: String, status: String, content: String?, rawInput: String?, rawOutput: String?, meta: AnyJSON?)
    case toolCallUpdate(id: String, title: String?, status: String?, content: String?, rawInput: String?, rawOutput: String?, append: Bool, meta: AnyJSON?)
    case turnComplete(stopReason: String)
    case sessionStarted(sessionId: String)
    case conversationLinked(conversationId: Int, folderId: Int)
    case conversationStatusChanged(conversationId: Int, status: ConversationStatus)
    case statusChanged(status: ConnectionStatus)
    case usageUpdate(used: UInt64, size: UInt64)
    case userMessage(messageId: String, blocks: [UserMessageBlock])
    case userPromptSent(textPreview: String)
    case error(message: String, code: String?)
    /// Agent asks the user to approve a tool call before it runs. Also carries
    /// ExitPlanMode — the proposed plan rides inside `toolCall`. Resolve via
    /// `acp_respond_permission` with the chosen `option_id`.
    case permissionRequest(requestId: String, toolCall: AnyJSON, options: [PermissionOption])
    /// A pending permission was resolved (by this or another client) — clear the card.
    case permissionResolved(requestId: String)
    /// Agent asks one or more multiple-choice questions (`ask_user_question`).
    /// Resolve via `acp_answer_question`.
    case questionRequest(questionId: String, questions: [QuestionSpec])
    /// A pending question was resolved — clear the card.
    case questionResolved(questionId: String)
    /// Grok's native `exit_plan_mode`: the agent finished planning and is BLOCKED
    /// on the user's approval before it leaves plan mode and starts implementing.
    /// Resolve via `acp_answer_plan_approval`; also carried on the session
    /// snapshot so a mid-turn attach recovers it.
    case planApprovalRequest(approvalId: String, toolCallId: String, planMarkdown: String)
    /// A pending plan approval was answered (from any client) or canceled — clear
    /// the card. Idempotent on apply.
    case planApprovalResolved(approvalId: String)
    /// The agent's live plan / TODO list (display only; does not block the turn).
    case planUpdate(entries: [PlanEntry])
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, title, kind, status, content, meta
        case toolCallId, rawInput, rawOutput, rawOutputAppend
        case stopReason, sessionId, conversationId, folderId
        case used, size, messageId, blocks, message, code, textPreview
        case requestId, toolCall, options, questionId, questions, entries
        case approvalId, planMarkdown
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "content_delta":
            self = .contentDelta(text: try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking":
            self = .thinking(text: try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "tool_call":
            self = .toolCall(
                id: try c.decodeIfPresent(String.self, forKey: .toolCallId) ?? "",
                title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
                kind: try c.decodeIfPresent(String.self, forKey: .kind) ?? "",
                status: try c.decodeIfPresent(String.self, forKey: .status) ?? "",
                content: try c.decodeIfPresent(String.self, forKey: .content),
                rawInput: try c.decodeIfPresent(String.self, forKey: .rawInput),
                rawOutput: try c.decodeIfPresent(String.self, forKey: .rawOutput),
                meta: try c.decodeIfPresent(AnyJSON.self, forKey: .meta)
            )
        case "tool_call_update":
            self = .toolCallUpdate(
                id: try c.decodeIfPresent(String.self, forKey: .toolCallId) ?? "",
                title: try c.decodeIfPresent(String.self, forKey: .title),
                status: try c.decodeIfPresent(String.self, forKey: .status),
                content: try c.decodeIfPresent(String.self, forKey: .content),
                // Some hosts deliver the arguments on a later update rather than the
                // initial tool_call (or only ever send updates). Capture it so live
                // companion classification (which keys off the input shape) works.
                rawInput: try c.decodeIfPresent(String.self, forKey: .rawInput),
                rawOutput: try c.decodeIfPresent(String.self, forKey: .rawOutput),
                append: try c.decodeIfPresent(Bool.self, forKey: .rawOutputAppend) ?? false,
                // The delegate lifecycle patches `meta["codeg.delegation"]` to the
                // terminal status on an update so the live card stops reading "running".
                meta: try c.decodeIfPresent(AnyJSON.self, forKey: .meta)
            )
        case "turn_complete":
            self = .turnComplete(stopReason: try c.decodeIfPresent(String.self, forKey: .stopReason) ?? "end_turn")
        case "session_started":
            self = .sessionStarted(sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId) ?? "")
        case "conversation_linked":
            self = .conversationLinked(
                conversationId: try c.decodeIfPresent(Int.self, forKey: .conversationId) ?? 0,
                folderId: try c.decodeIfPresent(Int.self, forKey: .folderId) ?? 0
            )
        case "conversation_status_changed":
            self = .conversationStatusChanged(
                conversationId: try c.decodeIfPresent(Int.self, forKey: .conversationId) ?? 0,
                status: try c.decodeIfPresent(ConversationStatus.self, forKey: .status) ?? .other
            )
        case "status_changed":
            self = .statusChanged(status: try c.decodeIfPresent(ConnectionStatus.self, forKey: .status) ?? .error)
        case "usage_update":
            self = .usageUpdate(
                used: try c.decodeIfPresent(UInt64.self, forKey: .used) ?? 0,
                size: try c.decodeIfPresent(UInt64.self, forKey: .size) ?? 0
            )
        case "user_message":
            self = .userMessage(
                messageId: try c.decodeIfPresent(String.self, forKey: .messageId) ?? "",
                blocks: try c.decodeIfPresent([UserMessageBlock].self, forKey: .blocks) ?? []
            )
        case "user_prompt_sent":
            self = .userPromptSent(textPreview: try c.decodeIfPresent(String.self, forKey: .textPreview) ?? "")
        case "error":
            self = .error(
                message: try c.decodeIfPresent(String.self, forKey: .message) ?? "Unknown error",
                code: try c.decodeIfPresent(String.self, forKey: .code)
            )
        case "permission_request":
            self = .permissionRequest(
                requestId: try c.decodeIfPresent(String.self, forKey: .requestId) ?? "",
                toolCall: try c.decodeIfPresent(AnyJSON.self, forKey: .toolCall) ?? .null,
                options: try c.decodeIfPresent([PermissionOption].self, forKey: .options) ?? []
            )
        case "permission_resolved":
            self = .permissionResolved(requestId: try c.decodeIfPresent(String.self, forKey: .requestId) ?? "")
        case "question_request":
            self = .questionRequest(
                questionId: try c.decodeIfPresent(String.self, forKey: .questionId) ?? "",
                questions: try c.decodeIfPresent([QuestionSpec].self, forKey: .questions) ?? []
            )
        case "question_resolved":
            self = .questionResolved(questionId: try c.decodeIfPresent(String.self, forKey: .questionId) ?? "")
        case "plan_approval_request":
            self = .planApprovalRequest(
                approvalId: try c.decodeIfPresent(String.self, forKey: .approvalId) ?? "",
                toolCallId: try c.decodeIfPresent(String.self, forKey: .toolCallId) ?? "",
                // An empty/missing plan still opens the approval surface (Grok's
                // plan-mode doc allows it) — the card shows an empty-state notice.
                planMarkdown: try c.decodeIfPresent(String.self, forKey: .planMarkdown) ?? ""
            )
        case "plan_approval_resolved":
            self = .planApprovalResolved(approvalId: try c.decodeIfPresent(String.self, forKey: .approvalId) ?? "")
        case "plan_update":
            self = .planUpdate(entries: try c.decodeIfPresent([PlanEntry].self, forKey: .entries) ?? [])
        default:
            self = .unknown(type: type)
        }
    }
}

/// The flat ACP event envelope (Rust `EventEnvelope`): `{seq, connection_id,
/// type, ...payload}` — the payload is flattened, so we decode `seq` +
/// `connectionId` and then the event from the same container.
struct EventEnvelope: Sendable, Decodable {
    let seq: UInt64
    let connectionId: String
    let event: AcpEvent

    private enum CodingKeys: String, CodingKey { case seq, connectionId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        connectionId = try c.decodeIfPresent(String.self, forKey: .connectionId) ?? ""
        event = try AcpEvent(from: decoder)
    }
}

/// Projection of the live session snapshot delivered on attach (Rust
/// `LiveSessionSnapshot`). The scalar fields drive the send path; the
/// reconstruction fields (`liveMessage` / `activeToolCalls` / `pendingPermission`
/// / `pendingQuestion`) let `reattachIfLive()` rebuild an in-flight turn — and any
/// pending interactive card — when opening a session whose turn is still running.
///
/// All reconstruction fields decode with `try?`: a shape surprise yields `nil`
/// rather than failing the whole snapshot decode (the send path depends on this
/// decode succeeding on every `.snapshot` frame).
struct LiveSessionSnapshot: Sendable, Decodable {
    let connectionId: String?
    let conversationId: Int?
    let folderId: Int?
    let status: ConnectionStatus?
    let externalId: String?
    let eventSeq: UInt64?
    let liveMessage: LiveMessageSnapshot?
    let activeToolCalls: [ToolCallStateSnapshot]?
    let pendingPermission: PendingPermissionSnapshot?
    let pendingQuestion: PendingQuestionSnapshot?
    let pendingPlanApproval: PendingPlanApprovalSnapshot?

    private enum CodingKeys: String, CodingKey {
        case connectionId, conversationId, folderId, status, externalId, eventSeq
        case liveMessage, activeToolCalls, pendingPermission, pendingQuestion, pendingPlanApproval
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connectionId = try c.decodeIfPresent(String.self, forKey: .connectionId)
        conversationId = try c.decodeIfPresent(Int.self, forKey: .conversationId)
        folderId = try c.decodeIfPresent(Int.self, forKey: .folderId)
        status = try? c.decodeIfPresent(ConnectionStatus.self, forKey: .status)
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        eventSeq = try c.decodeIfPresent(UInt64.self, forKey: .eventSeq)
        liveMessage = (try? c.decodeIfPresent(LiveMessageSnapshot.self, forKey: .liveMessage)) ?? nil
        activeToolCalls = (try? c.decodeIfPresent([ToolCallStateSnapshot].self, forKey: .activeToolCalls)) ?? nil
        pendingPermission = (try? c.decodeIfPresent(PendingPermissionSnapshot.self, forKey: .pendingPermission)) ?? nil
        pendingQuestion = (try? c.decodeIfPresent(PendingQuestionSnapshot.self, forKey: .pendingQuestion)) ?? nil
        pendingPlanApproval = (try? c.decodeIfPresent(PendingPlanApprovalSnapshot.self, forKey: .pendingPlanApproval)) ?? nil
    }
}

/// In-flight assistant message carried by a snapshot (Rust `LiveMessage`).
struct LiveMessageSnapshot: Sendable, Decodable {
    let content: [LiveContentBlockSnapshot]

    private enum CodingKeys: String, CodingKey { case content }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent([LiveContentBlockSnapshot].self, forKey: .content) ?? []
    }
}

/// One ordered block of the in-flight message (Rust `LiveContentBlock`,
/// `kind`-tagged). `toolCallRef` points into `activeToolCalls` by id.
enum LiveContentBlockSnapshot: Sendable, Decodable {
    case text(String)
    case thinking(String)
    case toolCallRef(toolCallId: String)
    case plan(entries: AnyJSON)
    case unknown

    private enum CodingKeys: String, CodingKey { case kind, text, toolCallId, entries }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .kind) ?? "" {
        case "text": self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking": self = .thinking(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "tool_call_ref": self = .toolCallRef(toolCallId: try c.decodeIfPresent(String.self, forKey: .toolCallId) ?? "")
        case "plan": self = .plan(entries: try c.decodeIfPresent(AnyJSON.self, forKey: .entries) ?? .null)
        default: self = .unknown
        }
    }
}

/// One active tool call carried by a snapshot (Rust `ToolCallState`). `kind` /
/// `status` are bare strings; `input` / `output` are freeform JSON (`output` is
/// `{kind,...}`-tagged — text/error/json).
struct ToolCallStateSnapshot: Sendable, Decodable {
    let id: String
    let kind: String
    let label: String
    let status: String
    let input: AnyJSON?
    let output: AnyJSON?
    let content: String?
    let meta: AnyJSON?

    private enum CodingKeys: String, CodingKey { case id, kind, label, status, input, output, content, meta }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        input = try c.decodeIfPresent(AnyJSON.self, forKey: .input)
        output = try c.decodeIfPresent(AnyJSON.self, forKey: .output)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        meta = try c.decodeIfPresent(AnyJSON.self, forKey: .meta)
    }

    /// Flatten the `{kind,...}`-tagged output into plain text for the live card.
    var outputText: String {
        guard let o = output?.object else { return output?.string ?? "" }
        switch o["kind"]?.string {
        case "text": return o["content"]?.string ?? ""
        case "error": return o["message"]?.string ?? ""
        case "json": return o["value"].map { $0.prettyPrinted } ?? ""
        default: return ""
        }
    }

    /// The agent's argument JSON as a preview string (matches the event path's
    /// `raw_input`, which already arrives as a string).
    var inputPreview: String? {
        guard let input, !input.isNull else { return nil }
        if case .string(let s) = input { return s }
        return input.prettyPrinted
    }
}

/// Pending permission carried by a snapshot (Rust `PendingPermissionState`).
struct PendingPermissionSnapshot: Sendable, Decodable {
    let requestId: String
    let toolCall: AnyJSON
    let options: [PermissionOption]

    private enum CodingKeys: String, CodingKey { case requestId, toolCall, options }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId) ?? ""
        toolCall = try c.decodeIfPresent(AnyJSON.self, forKey: .toolCall) ?? .null
        options = try c.decodeIfPresent([PermissionOption].self, forKey: .options) ?? []
    }
}

/// Pending question carried by a snapshot (Rust `PendingQuestionState`).
struct PendingQuestionSnapshot: Sendable, Decodable {
    let questionId: String
    let questions: [QuestionSpec]

    private enum CodingKeys: String, CodingKey { case questionId, questions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questionId = try c.decodeIfPresent(String.self, forKey: .questionId) ?? ""
        questions = try c.decodeIfPresent([QuestionSpec].self, forKey: .questions) ?? []
    }
}

/// Pending Grok plan approval carried by a snapshot (Rust
/// `PendingPlanApprovalState`), so a client attaching mid-turn recovers the
/// blocked `exit_plan_mode` card instead of watching the turn spin.
struct PendingPlanApprovalSnapshot: Sendable, Decodable {
    let approvalId: String
    let toolCallId: String
    let planMarkdown: String

    private enum CodingKeys: String, CodingKey { case approvalId, toolCallId, planMarkdown }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approvalId = try c.decodeIfPresent(String.self, forKey: .approvalId) ?? ""
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId) ?? ""
        planMarkdown = try c.decodeIfPresent(String.self, forKey: .planMarkdown) ?? ""
    }
}

/// A registered agent on a server (Rust `AcpAgentInfo`). The structured per-type
/// config detail round-trips most of these: `env` + `modelProviderId` via
/// `acp_update_agent_env`, and the native config files (`configJson` and the
/// per-agent `*AuthJson` / `codexConfigToml` / `hermesConfigYaml`) via
/// `acp_update_agent_config` / `acp_update_hermes_config`. Every config field is
/// optional (`decodeIfPresent`) so a partial payload — or an older server that
/// omits some — can't fail the whole list decode.
///
/// SECURITY: unlike `ModelProviderInfo` (which masks `api_key`), the agent
/// endpoints return env/config in CLEARTEXT (real tokens live in `config.env`,
/// `cline` config, the auth JSONs, etc.). These are only ever held in-memory and
/// sent straight back to the dedicated endpoints — never persisted on device.
struct AcpAgentInfo: Decodable, Identifiable, Hashable, Sendable {
    let agentType: AgentType
    let registryId: String
    let name: String
    let description: String
    /// Custom-agent mark from the server. Built-ins leave this nil and use
    /// the shipped asset.
    let iconUrl: String?
    let available: Bool
    /// `var` (not `let`) so the agents list model can optimistically flip an
    /// agent's enabled state for the instant row/detail toggle, reverting on a
    /// failed write. Decoding is unaffected.
    var enabled: Bool
    let sortOrder: Int
    let installedVersion: String?
    let env: [String: String]?
    let modelProviderId: Int?

    // MARK: Version / distribution (drives the install/upgrade/uninstall row)
    /// Latest version the registry knows of (npm / GitHub releases). `nil` when
    /// the server couldn't reach the registry.
    let registryVersion: String?
    /// `"binary" | "npx" | "uvx" | "system"`. Optional + leniently handled:
    /// absent/unknown → no managed-version row (see ``AgentVersion/check(_:uvReady:)``).
    let distributionType: String?

    // MARK: Native config files (per-type; most are nil for a given agent)
    /// The agent's `config.json` as a raw JSON string (claude/gemini/openclaw use
    /// merge-on-save; opencode/cline replace; hermes' is a backend projection).
    let configJson: String?
    /// Display-only path of the on-disk config file.
    let configFilePath: String?
    /// `open_code` `~/.config/opencode/auth.json` (provider apiKeys mirror here).
    let opencodeAuthJson: String?
    /// `codex` `~/.codex/auth.json` (set by the ChatGPT OAuth flow; read-only here).
    let codexAuthJson: String?
    /// `codex` `~/.codex/config.toml` (reasoning effort / websockets / skills / fast).
    let codexConfigToml: String?
    /// `cline` secrets file — decode-only; cline keeps its apiKey inline in
    /// `configJson`, so nothing is written back here (vestigial, kept for decode
    /// compatibility).
    let clineSecretsJson: String?
    /// `hermes` raw `~/.hermes/config.yaml` (the "advanced / raw" editor source).
    let hermesConfigYaml: String?
    /// `grok` raw `~/.grok/config.toml` (the Advanced escape-hatch editor source).
    let grokConfigToml: String?
    /// `grok` parsed scalar settings (permission mode / reasoning effort) backing
    /// the structured controls — derived server-side from `grokConfigToml`.
    let grokSettings: GrokSettings?
    /// `cursor` raw `~/.cursor/cli-config.json` (the Advanced escape-hatch editor
    /// source). Shared with the Cursor CLI's own `/config` UI.
    let cursorCliConfigJson: String?
    /// `cursor` parsed scalar settings (sandbox mode / permission rules) backing
    /// the structured controls — derived server-side from `cursorCliConfigJson`.
    let cursorSettings: CursorSettings?

    var id: String { registryId }
}

/// Parsed scalar keys from `~/.grok/config.toml` backing the Grok panel's
/// structured controls (`nil` = the key is absent). Serialized snake_case by the
/// backend (`default_reasoning_effort` / `permission_mode`), so the shared
/// `.convertFromSnakeCase` decoder maps them to these camelCase props.
struct GrokSettings: Decodable, Hashable, Sendable {
    let defaultReasoningEffort: String?
    let permissionMode: String?
}

/// The subset of `~/.cursor/cli-config.json` codeg manages, projected by the
/// backend (`sandbox_mode` / `permissions_allow` / `permissions_deny` → camelCase
/// here via the shared decoder). Everything else in the file is preserved
/// verbatim on write, so this is a view, not the whole document. The rule lists
/// default to empty rather than failing when the key is absent.
struct CursorSettings: Decodable, Hashable, Sendable {
    let sandboxMode: String?
    let permissionsAllow: [String]
    let permissionsDeny: [String]

    private enum CodingKeys: String, CodingKey { case sandboxMode, permissionsAllow, permissionsDeny }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sandboxMode = try c.decodeIfPresent(String.self, forKey: .sandboxMode)
        permissionsAllow = try c.decodeIfPresent([String].self, forKey: .permissionsAllow) ?? []
        permissionsDeny = try c.decodeIfPresent([String].self, forKey: .permissionsDeny) ?? []
    }
}
