import SwiftUI

/// The coding agents codeg can drive. Wire value is snake_case (serde
/// `rename_all = "snake_case"` on the Rust `AgentType` enum). Enum *values*
/// are unaffected by the decoder's key strategy, so raw values match directly.
enum AgentType: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case claudeCode = "claude_code"
    case codex = "codex"
    case openCode = "open_code"
    case gemini = "gemini"
    case openClaw = "open_claw"
    case cline = "cline"
    case hermes = "hermes"
    case codeBuddy = "code_buddy"
    case kimiCode = "kimi_code"
    case pi = "pi"
    case grok = "grok"
    case cursor = "cursor"
    /// User-registered ACP agent (`custom:<id>` on the wire). Must not decode
    /// as Claude or every extra account / future registry agent looks like Claude.
    case custom = "custom"
    /// Built-in added on the server after this app shipped, or a typo'd wire
    /// id. Same rule: never impersonate Claude.
    case unknown = "unknown"

    var id: String { rawValue }

    /// Decodes `custom:<id>` as `.custom` and any other unknown wire value as
    /// `.unknown`. Never fall back to `.claudeCode` — that made Grok (on
    /// builds that predated the `grok` case) and every custom agent render
    /// with Claude's name and mark.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let known = AgentType(rawValue: raw) {
            self = known
        } else if raw.hasPrefix("custom:") {
            self = .custom
        } else {
            self = .unknown
        }
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
        case .custom: return "Custom agent"
        case .unknown: return "Unknown agent"
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

    /// Name of the brand-icon image set in `Assets.xcassets` (the per-agent SVGs
    /// ported verbatim from the web client's `agent-icon.tsx`). Rendered by
    /// `AgentIcon`.
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

    /// Whether the brand asset is a monochrome (template) glyph that should be
    /// tinted by the caller. Mirrors the web's `MONO_ICONS` set (OpenCode, Cline,
    /// Hermes, CodeBuddy, Grok, Cursor); the others carry their own brand
    /// colors/gradients and render as-is.
    var iconIsTemplate: Bool {
        switch self {
        case .openCode, .cline, .hermes, .codeBuddy, .grok, .cursor, .custom, .unknown: return true
        case .claudeCode, .codex, .gemini, .openClaw, .kimiCode, .pi: return false
        }
    }

    /// Accent color used for badges / avatars per agent.
    var accent: Color {
        switch self {
        case .claudeCode: return Color(red: 0.85, green: 0.52, blue: 0.34) // claude clay
        case .codex: return Color(red: 0.45, green: 0.78, blue: 0.66)      // teal
        case .openCode: return Color(red: 0.55, green: 0.62, blue: 0.95)   // indigo
        case .gemini: return Color(red: 0.50, green: 0.70, blue: 0.98)     // blue
        case .openClaw: return Color(red: 0.92, green: 0.62, blue: 0.42)   // amber
        case .cline: return Color(red: 0.62, green: 0.78, blue: 0.50)      // green
        case .hermes: return Color(red: 0.60, green: 0.50, blue: 0.85)     // violet
        case .codeBuddy: return Color(red: 0.20, green: 0.47, blue: 0.96)  // tencent blue
        case .kimiCode: return Color(red: 0.09, green: 0.51, blue: 1.0)    // moonshot blue
        case .pi: return Color(red: 0.22, green: 0.22, blue: 0.26)         // pi slate
        // xAI's mark is monochrome (web `bg-neutral-900`); a static near-black
        // would vanish on the dark card, so tint dynamically — near-black in
        // light, near-white in dark — mirroring the brand while staying legible.
        case .grok: return Color(light: Color(white: 0.12), dark: Color(white: 0.92))
        // Cursor's cube mark is monochrome too (web renders it at plain
        // `text-foreground`), so it gets the same appearance-following tint.
        case .cursor: return Color(light: Color(white: 0.12), dark: Color(white: 0.92))
        case .custom, .unknown: return Color(light: Color(white: 0.35), dark: Color(white: 0.75))
        }
    }
}
