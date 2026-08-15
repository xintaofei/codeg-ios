import SwiftUI

/// Circular agent avatar showing the per-agent brand icon.
struct AgentAvatar: View {
    let agent: AgentType
    var size: CGFloat = 36
    var remoteURL: URL? = nil

    var body: some View {
        AgentIcon(agent: agent, remoteURL: remoteURL)
            .frame(width: size * 0.56, height: size * 0.56)
            .frame(width: size, height: size)
            .background(agent.accent.opacity(0.16), in: Circle())
            .overlay(Circle().strokeBorder(agent.accent.opacity(0.32), lineWidth: 1))
    }
}

/// A circular, bordered section icon that mirrors ``AgentAvatar``'s shape so
/// group headers (folder / Pinned / Running) visually rhyme with the agent
/// avatars in their rows — and, at the same 26pt diameter, line the header title
/// up with the row titles beneath it. The tint carries the folder color (or an
/// accent) into both the fill and the stroke, replacing the old bare color dot.
struct SectionBadgeIcon: View {
    let systemImage: String
    var tint: Color = Theme.accent
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.32), lineWidth: 1))
    }
}

/// A folder's colored "workspace tile": a rounded square in the folder's color
/// with a folder glyph. Squared off — unlike the circular ``SectionBadgeIcon`` /
/// ``AgentAvatar`` — so it reads as a folder and stays visually distinct from the
/// round agent avatars in the session lists. Size-scalable: the corner radius and
/// glyph track `size`, so the same badge serves the Folders list rows (40) and the
/// larger folder-detail hero. At `size: 40` it matches the original list tile
/// (radius 12, glyph 17).
struct FolderBadge: View {
    let color: Color
    var size: CGFloat = 40

    private var cornerRadius: CGFloat { size * 0.3 }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color.opacity(0.18))
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(color.opacity(0.40), lineWidth: 1)
            )
            .overlay(
                Image(systemName: "folder.fill")
                    .font(.system(size: size * 0.425, weight: .semibold))
                    .foregroundStyle(color)
            )
    }
}

/// A rounded, accent-tinted tile holding an SF Symbol — the polished "app icon"
/// treatment shared by the Experts and Skills list rows (and their detail heroes).
/// Size-scalable: the corner radius and glyph track `size`, so one component
/// serves the 40pt list tiles and the larger detail heroes. `tint` defaults to the
/// app accent; pass another color to recolor the whole tile.
struct AccentIconTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 40

    private var cornerRadius: CGFloat { size * 0.27 }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(tint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.16), lineWidth: 0.75)
            )
    }
}

/// Small pill showing a group's item count, used in section headers.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// Compact agent capsule (brand icon + short name).
struct AgentBadge: View {
    let agent: AgentType

    var body: some View {
        HStack(spacing: 4) {
            AgentIcon(agent: agent).frame(width: 11, height: 11)
            Text(agent.shortName).font(.caption2.weight(.semibold))
                .foregroundStyle(agent.accent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(agent.accent.opacity(0.14), in: Capsule())
    }
}

/// Conversation status capsule with a status dot.
struct StatusBadge: View {
    let status: ConversationStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(status.tint).frame(width: 6, height: 6)
            Text(status.label).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.tint.opacity(0.14), in: Capsule())
    }
}

/// A live "running" indicator with a pulsing dot.
struct LivePulse: View {
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Theme.accent, lineWidth: 2)
                    .scaleEffect(animate ? 2.2 : 1)
                    .opacity(animate ? 0 : 0.8)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}
