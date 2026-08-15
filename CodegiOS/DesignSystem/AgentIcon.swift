import SwiftUI
import UIKit

/// The per-agent brand icon, mirroring the web client's `AgentIcon`
/// (`src/components/agent-icon.tsx`). Color agents (Claude Code, Codex, Gemini,
/// OpenClaw, Kimi Code, Pi) render their own colors/gradients from a vector
/// asset; monochrome agents (OpenCode, Cline, Hermes, CodeBuddy, Grok) are
/// template glyphs tinted by `tint`.
///
/// The icons live in `Assets.xcassets` as vector SVGs ported verbatim from the
/// web, so they scale crisply at any size — render inside a fixed frame.
struct AgentIcon: View {
    let agent: AgentType
    /// Tint applied to monochrome (template) agents. Color agents ignore it.
    var tint: Color
    /// Remote mark from the server (`icon_url` on a custom agent). Used when
    /// present so extra accounts do not share Claude's icon.
    var remoteURL: URL?

    init(agent: AgentType, tint: Color? = nil, remoteURL: URL? = nil) {
        self.agent = agent
        self.tint = tint ?? agent.accent
        self.remoteURL = remoteURL
    }

    var body: some View {
        if let remoteURL {
            AsyncImage(url: remoteURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                default:
                    localMark
                }
            }
        } else {
            localMark
        }
    }

    @ViewBuilder
    private var localMark: some View {
        if UIImage(named: agent.iconAsset) != nil {
            Image(agent.iconAsset)
                .renderingMode(agent.iconIsTemplate ? .template : .original)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
        } else {
            Image(systemName: agent.symbolName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
        }
    }
}
