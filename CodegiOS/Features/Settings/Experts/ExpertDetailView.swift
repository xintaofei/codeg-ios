import SwiftUI
import Observation

/// Expert detail: a markdown preview of the expert's content and a per-agent
/// enable/disable matrix (link / unlink the expert into each agent's skills).
struct ExpertDetailView: View {
    let expert: ExpertListItem
    let agents: [AgentType]
    let client: CodegClient?

    @State private var model: ExpertDetailModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(expert: ExpertListItem, agents: [AgentType], client: CodegClient?) {
        self.expert = expert
        self.agents = agents
        self.client = client
        _model = State(initialValue: ExpertDetailModel(expertId: expert.id, client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    agentsSection
                    contentSection
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(expert.metadata.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var header: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    ExpertIconTile(icon: expert.metadata.icon, size: 56)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(expert.metadata.localizedName)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        CategoryPill(label: ExpertCategory.label(expert.metadata.category))
                    }
                    Spacer(minLength: 8)
                }
                if let description = expert.metadata.localizedDescription, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The expert's identifier on its own line — selectable for copying,
                // de-cluttered from the title row.
                Label(expert.metadata.id, systemImage: "number")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var agentsSection: some View {
        EditorSection(title: "Enable For", footer: "Links this expert into the selected agents' skills.") {
            if agents.isEmpty {
                Text("No agents available on this server.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            } else if model.isLoading {
                // Hold the toggles until link status is known. With an empty
                // `statusByAgent` every row would render as off + interactive, so
                // an already-linked agent would flash off and a tap could fire
                // against unknown (possibly blocked) state and race the in-flight
                // status fetch. `isLoading` is only true on the initial load — a
                // toggle's re-sync keeps it false, so the matrix never re-blanks.
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                    Text("Loading status…")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            } else {
                ForEach(Array(agents.enumerated()), id: \.element) { index, agent in
                    if index > 0 { rowDivider }
                    agentRow(agent)
                }
            }
        }
    }

    private func agentRow(_ agent: AgentType) -> some View {
        let status = model.statusByAgent[agent]
        let state = status?.state
        let isLinked = state?.isLinked ?? false
        // Foreign/blocked/broken links can't be cleanly toggled on (mirrors the
        // web disabling the switch for these states); show why instead.
        let blocked = state == .linkedElsewhere || state == .blockedByRealDirectory || state == .broken
        let caption = Self.caption(state: state, copyMode: status?.copyMode ?? false)
        return HStack(spacing: 12) {
            AgentIcon(agent: agent)
                .frame(width: 20, height: 20)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.label)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                if let caption {
                    Text(caption.text)
                        .font(.caption2)
                        .foregroundStyle(caption.color)
                }
            }
            Spacer(minLength: 12)
            if model.togglingAgents.contains(agent) {
                ProgressView().controlSize(.small).tint(Theme.accent)
            }
            Toggle("", isOn: Binding(
                get: { isLinked },
                set: { on in Task { await model.toggle(agent, on: on) } }
            ))
            .labelsHidden()
            .tint(Theme.accent)
            .disabled(model.togglingAgents.contains(agent) || (blocked && !isLinked))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13) // matches the FieldRow / settings-row template
    }

    /// Inset hairline between agent rows — starts at the agent name (past the
    /// 34pt icon tile + its 12pt gap), not the card edge, so the list reads as a
    /// grouped iOS-style table rather than full-width rules.
    private var rowDivider: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 16 + 34 + 12)
    }

    /// The sub-label under an agent: a positive accent "Linked" when active, the
    /// copy-mode note, or the reason a link is blocked/broken. `nil` for the plain
    /// not-linked state (the off toggle already says that).
    private static func caption(state: ExpertLinkState?, copyMode: Bool) -> (text: String, color: Color)? {
        switch state {
        case .linkedToCodeg: return copyMode ? ("Copied (no symlink)", Theme.textTertiary) : ("Linked", Theme.accent)
        case .linkedElsewhere: return ("Linked elsewhere", Theme.textTertiary)
        case .blockedByRealDirectory: return ("Blocked by an existing directory", Theme.textTertiary)
        case .broken: return ("Broken link", Theme.danger)
        case .notLinked, .none: return nil
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if model.isLoading && model.content.isEmpty {
            LoadingView(label: "Loading…")
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        } else if !model.content.isEmpty {
            EditorSection(title: "Preview") {
                MarkdownContent(raw: Self.stripFrontmatter(model.content))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
        }
    }

    /// Drop a leading YAML frontmatter block (`---\n…\n---`) before rendering,
    /// matching the web's `stripFrontmatter`.
    private static func stripFrontmatter(_ content: String) -> String {
        // Trim `.whitespacesAndNewlines` on delimiter lines so a trailing CR from
        // CRLF files (`---\r`) is still recognized as a `---` fence.
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return content }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
            return content
        }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A small accent pill naming the expert's category (mirrors the MCP
/// `TransportBadge` style for a consistent settings look).
private struct CategoryPill: View {
    let label: String

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.accentDim, in: Capsule())
    }
}

/// Loads an expert's markdown content + per-agent link state, and links/unlinks.
@MainActor
@Observable
final class ExpertDetailModel {
    let expertId: String
    private let client: CodegClient?

    private(set) var content: String = ""
    /// Full per-agent status (state + copyMode), so the UI can show the copy
    /// fallback and disable foreign/blocked links.
    private(set) var statusByAgent: [AgentType: ExpertInstallStatus] = [:]
    private(set) var isLoading = true
    private(set) var togglingAgents: Set<AgentType> = []
    var error: String?

    init(expertId: String, client: CodegClient?) {
        self.expertId = expertId
        self.client = client
    }

    func load() async {
        guard let client else { isLoading = false; error = "No server selected."; return }
        do {
            async let contentReq = client.expertContent(expertId: expertId)
            async let statusReq = client.expertInstallStatus(expertId: expertId)
            let (loadedContent, statuses) = try await (contentReq, statusReq)
            content = loadedContent
            statusByAgent = Dictionary(statuses.map { ($0.agentType, $0) }, uniquingKeysWith: { _, latest in latest })
            isLoading = false
            error = nil
        } catch {
            isLoading = false
            self.error = error.localizedDescription
        }
    }

    func toggle(_ agent: AgentType, on: Bool) async {
        guard let client, !togglingAgents.contains(agent) else { return }
        togglingAgents.insert(agent)
        defer { togglingAgents.remove(agent) }
        do {
            if on {
                statusByAgent[agent] = try await client.expertLink(expertId: expertId, agentType: agent)
            } else {
                try await client.expertUnlink(expertId: expertId, agentType: agent)
                if let prev = statusByAgent[agent] {
                    statusByAgent[agent] = ExpertInstallStatus(
                        expertId: prev.expertId, agentType: agent, state: .notLinked,
                        linkPath: prev.linkPath, targetPath: nil,
                        expectedTargetPath: prev.expectedTargetPath, copyMode: false
                    )
                }
            }
        } catch {
            self.error = error.localizedDescription
            await load() // re-sync the real state after a failed toggle
        }
    }
}
