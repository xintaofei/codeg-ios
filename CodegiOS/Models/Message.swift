import Foundation

/// Role of a rendered turn (Rust `TurnRole`).
enum TurnRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case system

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TurnRole(rawValue: raw) ?? .system
    }
}

/// Token usage for a single turn (Rust `TurnUsage`). All fields present on wire.
struct TurnUsage: Codable, Hashable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int

    var total: Int { inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens }
}

/// Inline image payload (Rust `ImageData`).
struct ImageData: Codable, Hashable, Sendable {
    let data: String
    let mimeType: String
    let uri: String?
}

/// What a sub-agent's own transcript says about the run it performed (Rust
/// `AgentExecutionStats`, on a `tool_result`).
///
/// Only the fields this client actually renders are decoded — the Rust struct
/// also carries per-kind tool tallies, token totals and the child's own tool
/// calls, none of which iOS shows today (a sub-agent's work is read by opening
/// its session, not by re-summarizing it here).
struct AgentExecutionStats: Codable, Hashable, Sendable {
    /// The child's own session id, when the sub-agent ran as a standalone
    /// session on disk rather than as chunks folded into the parent's stream.
    /// Grok is the case that has one: every `spawn_subagent` child is a full
    /// session, and grok forwards none of its work over ACP — so this id is the
    /// only route to what the child actually did. `nil` for every other agent.
    let childSessionId: String?
}

/// What a persisted `tool_use` block says about its own lifecycle (Rust
/// `ContentBlock::ToolUse.status`, `pending` / `in_progress` / `completed` /
/// `failed`).
///
/// `.unknown` — the field was absent, empty, or a value we don't know — means
/// exactly that: **unknown**, never "settled". Only an affirmative value may be
/// acted on, because absence of a status is not evidence of anything: today only
/// grok's parser records one, and it records it on calls that are already paired
/// with a placeholder result.
enum ToolUseStatus: Hashable, Sendable {
    case unknown
    /// `pending` / `in_progress` — the agent said this call was still working
    /// *as of the line that wrote it*. A transcript is a record, not a live feed,
    /// so this is only trustworthy while something else affirms the round is
    /// running (see `TranscriptTimeline`'s in-flight scope).
    case running
    case completed
    case failed

    init(wire: String?) {
        switch wire?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "pending", "in_progress": self = .running
        case "completed": self = .completed
        case "failed": self = .failed
        default: self = .unknown
        }
    }
}

/// A polymorphic block of message content (Rust `ContentBlock`, internally
/// tagged by `type` with snake_case variant names). Decode-only: the server is
/// the source of truth for transcripts; locally-constructed optimistic turns
/// build cases directly. Unknown future variants decode to `.unknown` instead
/// of throwing.
enum ContentBlock: Hashable, Sendable, Decodable {
    case text(String)
    case thinking(String)
    case image(ImageData)
    case imageGeneration(revisedPrompt: String?, image: ImageData?)
    case toolUse(id: String?, name: String, inputPreview: String?, status: ToolUseStatus, meta: AnyJSON?)
    /// `exitCode`: the command's exit status when the transcript keeps it as a
    /// field (pi's `bashExecution.exitCode`, Cursor's shell results,
    /// Antigravity's runs — codeg 0.30+). Nil means unknown: most agents only
    /// print it, and the activity timeline reads it from the output then.
    case toolResult(id: String?, outputPreview: String?, isError: Bool, agentStats: AgentExecutionStats?, exitCode: Int? = nil)
    /// The turn FAILED, in the agent's own words ("stream disconnected before
    /// completion: …", "API Error: 503 …") — Rust `ContentBlock::TurnError`
    /// (codeg 0.30+). Never agent prose: the parser puts it alone in a `system`
    /// turn that closes the failed round.
    case turnError(String)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        // NOTE: the decoder uses `.convertFromSnakeCase`, so wire keys arrive
        // here already camelCased — match them in camelCase.
        case type, text, data, mimeType, uri, revisedPrompt, image
        case toolUseId, toolName, inputPreview, status, meta
        case outputPreview, isError, agentStats, message, exitCode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking":
            self = .thinking(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "image":
            self = .image(ImageData(
                data: try c.decodeIfPresent(String.self, forKey: .data) ?? "",
                mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "image/png",
                uri: try c.decodeIfPresent(String.self, forKey: .uri)
            ))
        case "image_generation":
            self = .imageGeneration(
                revisedPrompt: try c.decodeIfPresent(String.self, forKey: .revisedPrompt),
                image: try c.decodeIfPresent(ImageData.self, forKey: .image)
            )
        case "tool_use":
            self = .toolUse(
                id: try c.decodeIfPresent(String.self, forKey: .toolUseId),
                name: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "tool",
                inputPreview: try c.decodeIfPresent(String.self, forKey: .inputPreview),
                status: ToolUseStatus(wire: try c.decodeIfPresent(String.self, forKey: .status)),
                // `meta["codeg.delegation"]` carries the delegate card's authoritative
                // terminal status; nil for tool uses without any meta.
                meta: try c.decodeIfPresent(AnyJSON.self, forKey: .meta)
            )
        case "tool_result":
            self = .toolResult(
                id: try c.decodeIfPresent(String.self, forKey: .toolUseId),
                outputPreview: try c.decodeIfPresent(String.self, forKey: .outputPreview),
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false,
                agentStats: try c.decodeIfPresent(AgentExecutionStats.self, forKey: .agentStats),
                // An i64 on the wire (a Windows exit status is an unsigned
                // 32-bit value); anything out of range is "unknown".
                exitCode: (try? c.decodeIfPresent(Int.self, forKey: .exitCode)) ?? nil
            )
        case "turn_error":
            self = .turnError(try c.decodeIfPresent(String.self, forKey: .message) ?? "")
        default:
            self = .unknown(type: type)
        }
    }
}

extension MessageTurn {
    /// A failed round's closing line: a `system` turn made only of `turn_error`
    /// blocks. Mirrors the web's `isTurnErrorTurn`.
    var isTurnErrorTurn: Bool {
        role == .system && !blocks.isEmpty && blocks.allSatisfy {
            if case .turnError = $0 { return true }
            return false
        }
    }

    /// The failure text a turn-error turn carries, joined.
    var turnErrorText: String {
        blocks.compactMap { block -> String? in
            if case .turnError(let m) = block { return m }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One turn in a conversation transcript (Rust `MessageTurn`).
struct MessageTurn: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let role: TurnRole
    let blocks: [ContentBlock]
    let timestamp: Date
    let usage: TurnUsage?
    let durationMs: Int?
    let model: String?
    let completedAt: Date?

    init(
        id: String,
        role: TurnRole,
        blocks: [ContentBlock],
        timestamp: Date,
        usage: TurnUsage? = nil,
        durationMs: Int? = nil,
        model: String? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.usage = usage
        self.durationMs = durationMs
        self.model = model
        self.completedAt = completedAt
    }
}
