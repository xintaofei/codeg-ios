import SwiftUI

/// The coding agents codeg can drive. Wire value is snake_case (serde
/// `rename_all = "snake_case"` on the Rust `AgentType` enum).
///
/// `custom:<id>` and unknown built-in ids keep their original wire token so a
/// later encode (create conversation, acp_connect, settings writes) does not
/// collapse to `"custom"` / `"unknown"` or impersonate Claude.
enum AgentType: Hashable, Sendable, Identifiable {
    case claudeCode
    case codex
    case openCode
    case gemini
    case openClaw
    case cline
    case hermes
    case codeBuddy
    case kimiCode
    case pi
    case grok
    case cursor
    /// User-registered ACP agent. Associated value is the full wire token
    /// (`custom:claude-code-2`).
    case custom(String)
    /// Built-in added on the server after this app shipped, or a typo'd wire
    /// id. Associated value is the original token.
    case unknown(String)

    var id: String { wireValue }

    /// Built-in cases only. Custom/unknown ids come from the live server list.
    static var allCases: [AgentType] {
        [
            .claudeCode, .codex, .openCode, .gemini, .openClaw, .cline,
            .hermes, .codeBuddy, .kimiCode, .pi, .grok, .cursor,
        ]
    }

    /// The token the server's `AgentType` enum understands.
    var wireValue: String {
        switch self {
        case .claudeCode: return "claude_code"
        case .codex: return "codex"
        case .openCode: return "open_code"
        case .gemini: return "gemini"
        case .openClaw: return "open_claw"
        case .cline: return "cline"
        case .hermes: return "hermes"
        case .codeBuddy: return "code_buddy"
        case .kimiCode: return "kimi_code"
        case .pi: return "pi"
        case .grok: return "grok"
        case .cursor: return "cursor"
        case .custom(let raw), .unknown(let raw): return raw
        }
    }

    /// Compatibility with call sites that used `String` raw representable.
    var rawValue: String { wireValue }

    static func parse(_ raw: String) -> AgentType {
        switch raw {
        case "claude_code": return .claudeCode
        case "codex": return .codex
        case "open_code": return .openCode
        case "gemini": return .gemini
        case "open_claw": return .openClaw
        case "cline": return .cline
        case "hermes": return .hermes
        case "code_buddy": return .codeBuddy
        case "kimi_code": return .kimiCode
        case "pi": return .pi
        case "grok": return .grok
        case "cursor": return .cursor
        default:
            if raw.hasPrefix("custom:") {
                return .custom(raw)
            }
            return .unknown(raw)
        }
    }

    init?(rawValue: String) {
        self = Self.parse(rawValue)
    }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .openCode: return "OpenCode"
        case .gemini: return "Gemini CLI"
        case .openClaw: return "OpenClaw"
        case .cline: return "Cline"
        case .hermes: return "Hermes"
        case .codeBuddy: return "CodeBuddy"
        case .kimiCode: return "Kimi Code"
        case .pi: return "Pi"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .custom(let raw):
            let id = raw.dropFirst("custom:".count)
            return id.isEmpty ? "Custom agent" : String(id)
        case .unknown(let raw):
            return raw.isEmpty ? "Unknown agent" : raw
        }
    }

    /// Short label for dense badges.
    var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .gemini: return "Gemini"
        case .openClaw: return "OpenClaw"
        case .cline: return "Cline"
        case .hermes: return "Hermes"
        case .codeBuddy: return "CodeBuddy"
        case .kimiCode: return "Kimi"
        case .pi: return "Pi"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .custom: return "Custom"
        case .unknown: return "Unknown"
        }
    }

    /// SF Symbol fallback (used only if the brand asset is ever missing).
    var symbolName: String {
        switch self {
        case .claudeCode: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .openCode: return "curlybraces"
        case .gemini: return "diamond"
        case .openClaw: return "pawprint"
        case .cline: return "terminal"
        case .hermes: return "bolt.horizontal.circle"
        case .codeBuddy: return "hammer"
        case .kimiCode: return "moon.stars"
        case .pi: return "pi"
        case .grok: return "line.diagonal"
        case .cursor: return "cursorarrow"
        case .custom, .unknown: return "questionmark.circle"
        }
    }

    /// Name of the brand-icon image set in `Assets.xcassets`.
    var iconAsset: String {
        switch self {
        case .claudeCode: return "AgentClaudeCode"
        case .codex: return "AgentCodex"
        case .openCode: return "AgentOpenCode"
        case .gemini: return "AgentGemini"
        case .openClaw: return "AgentOpenClaw"
        case .cline: return "AgentCline"
        case .hermes: return "AgentHermes"
        case .codeBuddy: return "AgentCodeBuddy"
        case .kimiCode: return "AgentKimiCode"
        case .pi: return "AgentPi"
        case .grok: return "AgentGrok"
        case .cursor: return "AgentCursor"
        case .custom, .unknown: return "AgentUnknown"
        }
    }

    var iconIsTemplate: Bool {
        switch self {
        case .openCode, .cline, .hermes, .codeBuddy, .grok, .cursor, .custom, .unknown: return true
        case .claudeCode, .codex, .gemini, .openClaw, .kimiCode, .pi: return false
        }
    }

    var accent: Color {
        switch self {
        case .claudeCode: return Color(red: 0.85, green: 0.52, blue: 0.34)
        case .codex: return Color(red: 0.45, green: 0.78, blue: 0.66)
        case .openCode: return Color(red: 0.55, green: 0.62, blue: 0.95)
        case .gemini: return Color(red: 0.50, green: 0.70, blue: 0.98)
        case .openClaw: return Color(red: 0.92, green: 0.62, blue: 0.42)
        case .cline: return Color(red: 0.62, green: 0.78, blue: 0.50)
        case .hermes: return Color(red: 0.60, green: 0.50, blue: 0.85)
        case .codeBuddy: return Color(red: 0.20, green: 0.47, blue: 0.96)
        case .kimiCode: return Color(red: 0.09, green: 0.51, blue: 1.0)
        case .pi: return Color(red: 0.22, green: 0.22, blue: 0.26)
        case .grok: return Color(light: Color(white: 0.12), dark: Color(white: 0.92))
        case .cursor: return Color(light: Color(white: 0.12), dark: Color(white: 0.92))
        case .custom, .unknown: return Color(light: Color(white: 0.35), dark: Color(white: 0.75))
        }
    }
}

extension AgentType: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentType.parse(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
