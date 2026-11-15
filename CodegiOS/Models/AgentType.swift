import SwiftUI

/// The coding agents codeg can drive.
///
/// Wire value is the Rust `AgentType`'s `as_wire()` form: the twelve built-ins
/// keep their historical snake_case names, and a user-registered ACP agent
/// serializes as `custom:<registry-id>` (codeg ≥0.22.0). Anything this build
/// does not have hand-written support for lands in ``other(wire:)`` — which
/// carries the wire string VERBATIM so it round-trips untouched.
///
/// That verbatim round-trip is the whole point. The previous decoder folded
/// every unrecognized value into `.claudeCode`, which meant a custom agent was
/// not merely mislabeled: saving its env/config, toggling it, reordering, or
/// linking an expert all posted `agent_type: "claude_code"` and wrote one
/// agent's settings into another's. An unknown agent must stay unknown.
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
    // Built in since codeg 0.4x. None has a hand-written settings panel here
    // (``isManagedOnDesktop``).
    case deepSeek
    case qoder
    case antigravity
    case kiro
    case zCode
    case trae
    case commandCode
    case miniMaxCode

    /// An agent with no compile-time support here: a user-registered ACP agent
    /// (`custom:<registry-id>`) or a built-in added by a newer server. The
    /// associated value is the full wire string, not the bare id, so encoding is
    /// a straight echo of whatever the server sent.
    ///
    /// Display for these comes from the server — ``CustomAgentRegistry`` caches
    /// the `name`/`iconUrl` off `acp_list_agents`; the computed properties below
    /// are only the offline fallback.
    case other(wire: String)

    /// Wire prefix marking a user-registered ACP agent (Rust
    /// `CUSTOM_AGENT_WIRE_PREFIX`).
    static let customWirePrefix = "custom:"

    /// The twelve compile-time agents, in the server's declaration order. Use
    /// this wherever `allCases` was used: pickers and matrices can only offer
    /// what this build can configure. (Custom agents come from the server's
    /// agent list, not from a static set.)
    static let builtins: [AgentType] = [
        .claudeCode, .codex, .openCode, .gemini, .openClaw, .cline,
        .hermes, .codeBuddy, .kimiCode, .pi, .grok, .cursor,
        .deepSeek, .qoder, .antigravity, .kiro, .zCode, .trae, .commandCode, .miniMaxCode,
    ]

    /// Built-ins configured only in the codeg desktop app: this build has no
    /// panel for them, and the server keeps no local config file for most
    /// (`agent_local_config_path` is None), so a generic config editor would
    /// report a save and drop it. Their detail page says so instead.
    var isManagedOnDesktop: Bool {
        switch self {
        case .deepSeek, .qoder, .antigravity, .kiro, .zCode, .trae, .commandCode, .miniMaxCode: return true
        default: return false
        }
    }

    var id: String { rawValue }

    /// True for a user-registered ACP agent (`custom:<id>`). False for the
    /// built-ins AND for an unknown non-`custom:` value, which is a newer
    /// server's built-in rather than something the user added.
    var isCustom: Bool { rawValue.hasPrefix(Self.customWirePrefix) }

    /// The registry id behind `custom:<id>`; nil for everything else.
    var customId: String? {
        guard isCustom else { return nil }
        return String(rawValue.dropFirst(Self.customWirePrefix.count))
    }

    /// Whether this build has hand-written configuration support (native config
    /// files, per-agent panels, auth modes). False for ``other(wire:)``, whose
    /// settings screen is env-only — codeg cannot know where an arbitrary ACP
    /// agent keeps its config, and the server reports none for it
    /// (`agent_local_config_path` returns `None`).
    var isBuiltin: Bool {
        if case .other = self { return false }
        return true
    }
}

// MARK: - Wire representation

extension AgentType: RawRepresentable {
    /// Never fails: an unrecognized value becomes ``other(wire:)`` rather than
    /// nil, so no call site can silently substitute a different agent. Only an
    /// empty string is rejected.
    init?(rawValue: String) {
        switch rawValue {
        case "claude_code": self = .claudeCode
        case "codex": self = .codex
        case "open_code": self = .openCode
        case "gemini": self = .gemini
        case "open_claw": self = .openClaw
        case "cline": self = .cline
        case "hermes": self = .hermes
        case "code_buddy": self = .codeBuddy
        case "kimi_code": self = .kimiCode
        case "pi": self = .pi
        case "grok": self = .grok
        case "cursor": self = .cursor
        case "deepseek": self = .deepSeek
        case "qoder": self = .qoder
        case "antigravity": self = .antigravity
        case "kiro": self = .kiro
        case "zcode": self = .zCode
        case "trae": self = .trae
        case "command_code": self = .commandCode
        case "minimax_code": self = .miniMaxCode
        case "": return nil
        default: self = .other(wire: rawValue)
        }
    }

    var rawValue: String {
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
        case .deepSeek: return "deepseek"
        case .qoder: return "qoder"
        case .antigravity: return "antigravity"
        case .kiro: return "kiro"
        case .zCode: return "zcode"
        case .trae: return "trae"
        case .commandCode: return "command_code"
        case .miniMaxCode: return "minimax_code"
        case .other(let wire): return wire
        }
    }
}

extension AgentType: Codable {
    /// Explicit, so the `RawRepresentable` default (which throws on an
    /// unrecognized raw value) can't reject a custom agent.
    ///
    /// `AgentType(rawValue:)` rejects only the empty string — a value the server
    /// never emits (`AgentType::from_wire("")` is `None`). It lands on
    /// `.other(wire: "")` rather than a real agent: aliasing it to `.claudeCode`
    /// would re-create the exact corruption this type exists to prevent (a later
    /// toggle / reorder / save would then post `claude_code`), while throwing
    /// would fail an entire list decode over one malformed row.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentType(rawValue: raw) ?? .other(wire: raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Display

extension AgentType {
    /// The name to put on screen: the server's own for a custom agent, else
    /// ``displayName``. Reading it from a SwiftUI `body` also subscribes the
    /// view to ``CustomAgentRegistry``, so a row rendered before the agent list
    /// arrives re-renders from the slug to the real name once it does.
    @MainActor var label: String { CustomAgentRegistry.shared.label(for: self) }

    /// Offline fallback name. For ``other(wire:)`` this humanizes the registry
    /// id (`custom:my-agent` → "My Agent"); prefer ``label``, which uses the
    /// server's own name when it has been fetched.
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
        case .deepSeek: return "DeepSeek Harness"
        case .qoder: return "Qoder"
        case .antigravity: return "Google Antigravity"
        case .kiro: return "Kiro CLI"
        case .zCode: return "ZCode"
        case .trae: return "TRAE CLI"
        case .commandCode: return "Command Code"
        case .miniMaxCode: return "MiniMax Code"
        case .other:
            let humanized = Self.humanize(customId ?? rawValue)
            // Only reachable from a malformed empty wire value (see the decoder);
            // a blank row would be worse than saying so.
            return humanized.isEmpty ? String(localized: "Unknown Agent") : humanized
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
        case .deepSeek: return "DeepSeek"
        case .qoder: return "Qoder"
        case .antigravity: return "Antigravity"
        case .kiro: return "Kiro"
        case .zCode: return "ZCode"
        case .trae: return "TRAE"
        case .commandCode: return "Command Code"
        case .miniMaxCode: return "MiniMax"
        case .other: return displayName
        }
    }

    /// `custom:my-agent` / `my_agent` → "My Agent".
    private static func humanize(_ slug: String) -> String {
        let words = slug
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? slug : words.joined(separator: " ")
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
        case .deepSeek: return "fish"
        case .qoder: return "q.circle"
        case .antigravity: return "arrow.up.circle"
        case .kiro: return "theatermasks"
        case .zCode: return "z.square"
        case .trae: return "square.dashed"
        case .commandCode: return "command"
        case .miniMaxCode: return "m.square"
        case .other: return "puzzlepiece.extension"
        }
    }

    /// Name of the brand-icon image set in `Assets.xcassets` (the per-agent SVGs
    /// ported verbatim from the web client's `agent-icon.tsx`). Rendered by
    /// `AgentIcon`. Nil for ``other(wire:)``, which ships no compiled asset.
    var iconAsset: String? {
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
        case .deepSeek: return "AgentDeepSeek"
        case .qoder: return "AgentQoder"
        case .antigravity: return "AgentAntigravity"
        case .kiro: return "AgentKiro"
        case .zCode: return "AgentZCode"
        case .trae: return "AgentTrae"
        case .commandCode: return "AgentCommandCode"
        case .miniMaxCode: return "AgentMiniMaxCode"
        case .other: return nil
        }
    }

    /// Whether the brand asset is a monochrome (template) glyph that should be
    /// tinted by the caller. Mirrors the web's `MONO_ICONS` set (OpenCode, Cline,
    /// Hermes, CodeBuddy, Grok, Cursor); the others carry their own brand
    /// colors/gradients and render as-is.
    var iconIsTemplate: Bool {
        switch self {
        case .openCode, .cline, .hermes, .codeBuddy, .grok, .cursor, .qoder, .antigravity: return true
        case .claudeCode, .codex, .gemini, .openClaw, .kimiCode, .pi,
             .deepSeek, .kiro, .zCode, .trae, .commandCode, .miniMaxCode: return false
        // A downloaded icon is rendered as-is; the monogram fallback tints itself.
        case .other: return false
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
        // The web's AGENT_COLORS. ZCode and Command Code are near-black marks,
        // so they follow the appearance like Grok and Cursor.
        case .deepSeek: return Color(red: 0.30, green: 0.42, blue: 1.0)      // #4D6BFE
        case .qoder: return Color(red: 0.42, green: 0.30, blue: 0.95)        // #6C4CF1
        case .antigravity: return Color(red: 0.10, green: 0.45, blue: 0.91)  // #1A73E8
        case .kiro: return Color(red: 0.56, green: 0.27, blue: 1.0)          // #9046FF
        case .zCode, .commandCode: return Color(light: Color(white: 0.12), dark: Color(white: 0.92))
        case .trae: return Color(red: 0.20, green: 0.94, blue: 0.55)         // #32F08C
        case .miniMaxCode: return Color(red: 0.95, green: 0.25, blue: 0.36)  // #F23F5D
        // A custom agent has no brand color, so derive a stable one from its id:
        // two agents stay visually distinct in a list, and the same agent keeps
        // its color across launches. Saturation/brightness are pinned to a band
        // that stays legible against both the light and dark card fills.
        case .other: return Color(hue: Self.stableHue(rawValue), saturation: 0.52, brightness: 0.78)
        }
    }

    /// A hue in `0..<1` derived from the wire string. FNV-1a rather than
    /// `hashValue`: Swift seeds its hasher per process, so the color would
    /// change on every launch.
    private static func stableHue(_ seed: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x1000_0000_01b3
        }
        return Double(hash % 360) / 360.0
    }
}
