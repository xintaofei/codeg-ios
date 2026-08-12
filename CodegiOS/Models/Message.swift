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
    case toolResult(id: String?, outputPreview: String?, isError: Bool)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        // NOTE: the decoder uses `.convertFromSnakeCase`, so wire keys arrive
        // here already camelCased — match them in camelCase.
        case type, text, data, mimeType, uri, revisedPrompt, image
        case toolUseId, toolName, inputPreview, status, meta
        case outputPreview, isError
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
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            )
        default:
            self = .unknown(type: type)
        }
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
