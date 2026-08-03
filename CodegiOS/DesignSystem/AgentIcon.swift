import SwiftUI
import UIKit

/// The per-agent brand icon, mirroring the web client's `AgentIcon`
/// (`src/components/agent-icon.tsx`). Color agents (Claude Code, Codex, Gemini,
/// OpenClaw, Kimi Code, Pi) render their own colors/gradients from a vector
/// asset; monochrome agents (OpenCode, Cline, Hermes, CodeBuddy, Grok, Cursor)
/// are template glyphs tinted by `tint`.
///
/// The icons live in `Assets.xcassets` as vector SVGs ported verbatim from the
/// web, so they scale crisply at any size — render inside a fixed frame.
///
/// A user-registered ACP agent (``AgentType/other(wire:)``) has no compiled
/// asset. Its mark comes from ``CustomAgentRegistry`` when the server sent a
/// raster icon; otherwise it falls back to a tinted monogram in the agent's
/// derived color, which is the common case (the server inlines the ACP
/// registry's marks as SVG, and UIKit cannot rasterize SVG at runtime).
struct AgentIcon: View {
    let agent: AgentType
    /// Tint applied to monochrome (template) agents. Color agents ignore it.
    var tint: Color

    init(agent: AgentType, tint: Color? = nil) {
        self.agent = agent
        self.tint = tint ?? agent.accent
    }

    var body: some View {
        if let asset = agent.iconAsset, UIImage(named: asset) != nil {
            Image(asset)
                // Be explicit about intent rather than relying on the asset's
                // configured rendering intent: mono agents tint, color render as-is.
                .renderingMode(agent.iconIsTemplate ? .template : .original)
                .resizable()
                .scaledToFit()
                // A template image adopts this; an original (color) image ignores it.
                .foregroundStyle(tint)
        } else if let custom = CustomAgentRegistry.shared.icon(for: agent) {
            Image(uiImage: custom)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
        } else if !agent.isBuiltin {
            AgentMonogram(agent: agent, tint: tint)
        } else {
            // Defensive fallback if a built-in's brand asset is ever missing/renamed.
            Image(systemName: agent.symbolName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
        }
    }
}

/// Up to two letters standing in for a custom agent's brand mark. Sized off the
/// container the way a glyph would be, so it drops into every `AgentIcon` frame
/// (26pt session rows through 56pt settings headers) without per-site tuning.
private struct AgentMonogram: View {
    let agent: AgentType
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            Text(CustomAgentRegistry.shared.label(for: agent).monogramInitials)
                .font(.system(size: geo.size.height * 0.62, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(tint)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

extension String {
    /// "My Agent" → "MA"; "goose" → "GO". Derived from the *displayed* label so
    /// the monogram tracks the server's name once it loads, rather than the
    /// humanized slug it started from.
    var monogramInitials: String {
        let words = split(separator: " ").prefix(2)
        let initials = words.compactMap { $0.first }
        if initials.count >= 2 { return String(initials).uppercased() }
        return String(prefix(2)).uppercased()
    }
}
