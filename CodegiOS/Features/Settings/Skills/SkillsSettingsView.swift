import SwiftUI

/// Markdown skill files per agent. A pinned agent selector at the top (a dropdown
/// on a material strip) chooses whose skills to show; below it the selected agent's
/// skills grouped by scope, with an add/edit markdown sheet.
struct SkillsSettingsView: View {
    @State private var model: SkillsSettingsModel
    @State private var editorRoute: EditorRoute?
    @State private var pendingDelete: PendingDelete?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum EditorRoute: Identifiable {
        case add
        case edit(AgentSkillItem)
        var id: String {
            switch self {
            case .add: "add"
            case .edit(let s): "edit-\(s.scope.rawValue)-\(s.id)"
            }
        }
    }

    /// Captures both the skill AND the agent it belongs to, so a confirm that
    /// fires after an agent switch still deletes from the correct agent.
    struct PendingDelete: Identifiable {
        let skill: AgentSkillItem
        let agent: AgentType
        var id: String { "\(agent.rawValue)-\(skill.scope.rawValue)-\(skill.id)" }
    }

    init(client: CodegClient?) {
        _model = State(initialValue: SkillsSettingsModel(client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        // A standard large title (not the pinned `inlineLarge` other settings
        // pages use): on compact it sits big at the top and collapses to a
        // centered inline title as the skills list scrolls up. iPad keeps the
        // system default for a detail pane.
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(horizontalSizeClass == .compact ? .large : .automatic)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.selectedAgent != nil, model.result?.supported == true {
                    Button { editorRoute = .add } label: { Image(systemName: "plus") }
                        .tint(Theme.accent)
                        .accessibilityLabel("New Skill")
                }
            }
        }
        .sheet(item: $editorRoute) { editorSheet($0) }
        .confirmationDialog(
            "Delete Skill",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { pending in
            Button("Delete \(pending.skill.name.isEmpty ? pending.skill.id : pending.skill.name)", role: .destructive) {
                Task { await model.delete(pending.skill, agent: pending.agent) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("Remove the skill file “\(pending.skill.id)”. This can't be undone.")
        }
        .task { await model.load() }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading where model.agents.isEmpty:
            LoadingView(label: "Loading…")
        case .failed(let message) where model.agents.isEmpty:
            InlineErrorView(message: message) { Task { await model.load() } }
        default:
            // The agent selector rides a top safe-area inset so the skills list is
            // flush with the nav bar (letting the large title collapse) while the
            // selector stays pinned and the list scrolls beneath it.
            skillsArea
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.selectedAgent != nil { agentBar }
                }
        }
    }

    /// A pinned header strip holding the agent selector, on a material background
    /// with a bottom hairline (the app's pinned-bar pattern) so the skills list
    /// scrolls cleanly beneath it instead of refracting through stacked glass.
    private var agentBar: some View {
        HStack(spacing: 0) {
            AgentSelectorPill(
                agents: model.agents,
                selected: model.selectedAgent,
                onSelect: { agent in Task { await model.select(agent) } }
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Layout.screenHMargin)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
    }

    @ViewBuilder
    private var skillsArea: some View {
        if model.skillsLoading && model.result == nil {
            LoadingView(label: "Loading skills…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.result == nil, let error = model.refreshError {
            // A failed read must not masquerade as an empty catalog.
            InlineErrorView(message: error) { Task { await model.reloadCurrent() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = model.result, !result.supported {
            EmptyStateView(
                icon: "wand.and.stars.inverse",
                title: "Not Supported",
                message: LocalizedStringKey(stringLiteral: result.message ?? "This agent doesn’t support skills.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.grouped.isEmpty {
            EmptyStateView(
                icon: "wand.and.stars",
                title: "No Skills",
                message: "Create a skill to guide this agent.",
                actionTitle: "New Skill",
                action: { editorRoute = .add }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            skillsList
        }
    }

    private var skillsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let error = model.refreshError {
                    RefreshErrorBanner(
                        message: error,
                        retry: { Task { await model.reloadCurrent() } },
                        dismiss: { model.refreshError = nil }
                    )
                }
                ForEach(model.grouped, id: \.scope) { group in
                    // Interpolate a localized `Text` (not a raw String) so the scope
                    // word translates; the format key becomes "%@ · %lld".
                    Text("\(group.scope == .global ? Text("GLOBAL") : Text("PROJECT")) · \(group.items.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .tracking(0.5)
                        .padding(.top, 6)
                        .padding(.leading, 4)
                    ForEach(group.items) { skill in
                        SkillRow(skill: skill)
                            .contentShape(.rect)
                            .onTapGesture { editorRoute = .edit(skill) }
                            .contextMenu {
                                Button { editorRoute = .edit(skill) } label: {
                                    Label(skill.readOnly ? "View" : "Edit", systemImage: skill.readOnly ? "eye" : "pencil")
                                }
                                if !skill.readOnly, let agent = model.resultAgent {
                                    Divider()
                                    Button(role: .destructive) { pendingDelete = PendingDelete(skill: skill, agent: agent) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, Theme.Layout.screenHMargin)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.reloadCurrent() }
    }

    @ViewBuilder
    private func editorSheet(_ route: EditorRoute) -> some View {
        // Capture the agent the displayed list belongs to and thread it through
        // every read/save, so the target can't drift if the selection changes.
        if let agent = model.resultAgent ?? model.selectedAgent {
            switch route {
            case .add:
                SkillEditorSheet(mode: .create, agent: agent, loadContent: { try await model.content(of: $0, agent: agent) }) { id, scope, content, layout in
                    try await model.save(skillId: id, scope: scope, content: content, layout: layout, agent: agent)
                }
            case .edit(let skill):
                SkillEditorSheet(mode: .edit(skill), agent: agent, loadContent: { try await model.content(of: $0, agent: agent) }) { id, scope, content, layout in
                    try await model.save(skillId: id, scope: scope, content: content, layout: layout, agent: agent)
                }
            }
        }
    }
}

/// One skill card, matching the adjacent Experts row: a tinted layout-icon tile
/// (folder for a skill directory, document for a single markdown file), the skill
/// name (+ read-only badge), and its description, with a chevron hinting it opens.
/// The file path moved to the editor sheet to keep the row uncluttered.
private struct SkillRow: View {
    let skill: AgentSkillItem

    private var layoutIcon: String {
        skill.layout == .skillDirectory ? "folder.fill" : "doc.text.fill"
    }

    var body: some View {
        GlassCard(cornerRadius: Theme.Radius.md, padding: 13) {
            HStack(spacing: 13) {
                AccentIconTile(symbol: layoutIcon, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(skill.name.isEmpty ? skill.id : skill.name)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if skill.readOnly { ReadOnlyBadge() }
                    }
                    if let description = skill.description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A small lock pill marking a built-in, read-only skill.
private struct ReadOnlyBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
            Text("READ-ONLY").font(.caption2.weight(.bold)).tracking(0.3)
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)   // keep intrinsic width; let the name truncate first
    }
}

/// The agent selector: a pill showing the current agent's brand icon + name with a
/// dropdown chevron, opening a menu of all agents (the system checkmarks the
/// current one). With a single agent it degrades to a static pill — no chevron, no
/// menu. The closed pill uses the icon's original colors or configured agent tint;
/// the menu itself is a text list (iOS tints menu glyphs monochrome regardless).
private struct AgentSelectorPill: View {
    let agents: [AgentType]
    let selected: AgentType?
    let onSelect: (AgentType) -> Void

    var body: some View {
        if agents.count > 1 {
            Menu {
                // Empty title (like `SelectField`) so no stray header shows; the
                // inline picker renders the agents with an automatic checkmark.
                Picker("", selection: selectionBinding) {
                    ForEach(agents) { agent in
                        Text(agent.label).tag(Optional(agent))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                pill(showsChevron: true)
            }
        } else {
            pill(showsChevron: false)
        }
    }

    /// Reads the model's selection; a pick routes through `onSelect` (which sets the
    /// selection synchronously before loading), so the checkmark updates at once.
    private var selectionBinding: Binding<AgentType?> {
        Binding(
            get: { selected },
            set: { if let agent = $0 { onSelect(agent) } }
        )
    }

    @ViewBuilder
    private func pill(showsChevron: Bool) -> some View {
        HStack(spacing: 8) {
            if let agent = selected {
                AgentIcon(agent: agent)
                    .frame(width: 18, height: 18)
                Text(agent.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.bgElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .contentShape(Capsule())
    }
}
