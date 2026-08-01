import SwiftUI

/// Draft new-session controls surfaced inside the agent button's sheet: pick the
/// agent + folder before the first send. `nil` for an existing conversation,
/// where the agent/folder are fixed and only Mode/config can change.
struct NewSessionAgentConfig {
    let availableAgents: [AgentType]
    let selectedAgent: AgentType
    let onSelectAgent: (AgentType) -> Void
    let availableFolders: [FolderDetail]
    let selectedFolder: FolderDetail?
    let onSelectFolder: (FolderDetail) -> Void
}

/// What a branch switch resolved to, so the picker knows whether to dismiss in
/// place or navigate. Mirrors the web's `BranchSwitchPlan` outcomes.
enum BranchSwitchOutcome {
    /// Already on the branch — nothing changed.
    case noop
    /// Checked out in the current folder's working tree; the row's checkmark moves.
    case switchedInPlace
    /// The branch lives in another worktree folder — open a new session there.
    case openSession(folderId: Int)
    /// The switch failed (a `notice` was surfaced).
    case failed
}

/// Folder + branch context for the agent options sheet, present for BOTH a draft
/// (folder switchable via `NewSessionAgentConfig`) and an existing session
/// (folder shown read-only). The branch is switchable in both cases. `folderPath`
/// nil → no git context, so the branch surface is hidden.
struct SessionBranchConfig {
    /// Display name — the ROOT repo's name when the session is in a worktree.
    let folderName: String?
    let folderPath: String?
    /// The current branch — seeds the row label + the picker's checkmark.
    let current: String?
    /// List branches for the picker (nil on failure).
    let load: () async -> GitBranchList?
    /// Switch to a branch (name, isRemote). Returns the navigation intent so the
    /// picker can dismiss in place or open a session in another worktree.
    let switchTo: (String, Bool) async -> BranchSwitchOutcome
    /// Create + check out a new branch (name, startPoint); true on success.
    let create: (String, String?) async -> Bool
    /// Navigate to a new draft session in `folderId` (a worktree the switch
    /// resolved to). `nil` when the host can't navigate (e.g. previews).
    var onOpenSession: ((Int) -> Void)? = nil
}

/// The circular agent avatar in the session detail's navigation bar (trailing).
/// Shows the conversation's (or draft's) agent glyph; tapping opens a sheet that
/// auto-loads the agent's Mode + config selectors. For a new-session draft it
/// additionally hosts the Agent + Folder pickers (`newSession`).
struct AgentOptionsButton: View {
    let agentType: AgentType
    let workingDir: String?
    let isBusy: Bool
    let options: AgentOptionsModel
    /// Present only for an editable new-session draft.
    var newSession: NewSessionAgentConfig? = nil
    /// Folder + branch context (draft and existing). nil → no git surfaces.
    var branch: SessionBranchConfig? = nil

    @State private var showSheet = false

    var body: some View {
        // iOS 26 already wraps a toolbar button in its own Liquid Glass circle, so
        // the bare brand glyph is all that's needed — `AgentAvatar`'s tinted disc +
        // ring would sit *inside* that glass as a redundant second border. Render
        // just the glyph and let the system glass be the single container, matching
        // the back button's clean single-ring look.
        Button { showSheet = true } label: {
            AgentIcon(agent: agentType)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(newSession == nil ? "Agent settings" : "Choose agent, folder, and options")
        .sheet(isPresented: $showSheet) {
            // `dismissSheet` lets the branch picker close the WHOLE sheet (not just
            // pop itself) before navigating to a worktree session — a `.sheet`
            // otherwise stays above the pushed destination.
            AgentOptionsSheet(
                isBusy: isBusy, options: options, newSession: newSession, branch: branch,
                dismissSheet: { showSheet = false }
            )
            .presentationDetents([.medium, .large])
            .presentationBackground(Theme.bg)
        }
        .onChange(of: showSheet) { _, shown in
            if shown { options.prepare(agentType: agentType, workingDir: workingDir) }
        }
    }
}

/// Sheet content: the draft's Agent/Folder pickers (new session only) above the
/// agent's auto-loaded Mode/config selectors.
private struct AgentOptionsSheet: View {
    let isBusy: Bool
    let options: AgentOptionsModel
    let newSession: NewSessionAgentConfig?
    let branch: SessionBranchConfig?
    /// Closes the entire options sheet (used by the branch picker before it
    /// navigates to a worktree session).
    var dismissSheet: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let newSession {
                            agentPicker(newSession)
                        }
                        // Folder + branch share one "Workspace" card: the folder
                        // (switchable on a draft, read-only on an existing session)
                        // above the branch selector.
                        if let branch, branch.folderPath != nil {
                            workspaceSection(newSession: newSession, branch: branch)
                        }

                        if isBusy {
                            hint(Text("Options can't be changed while the agent is responding."))
                        }

                        switch options.phase {
                        case .idle:
                            // Cheap snapshot/cache lookup (no agent spawn).
                            loadingRow("Loading options…")
                        case .loading:
                            // The probe path — a server-side agent is starting.
                            loadingRow("Starting the agent to read its options…")
                        case .failed(let message):
                            errorCard(message)
                        case .empty:
                            hint(Text("This agent has no configurable options."))
                        case .loaded:
                            selectors
                        }

                        if let notice = options.errorNotice {
                            hint(Text(verbatim: notice), tint: Theme.danger)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(newSession == nil ? Text("Options") : Text("New Session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    // MARK: - Draft pickers (new session)

    private func agentPicker(_ ns: NewSessionAgentConfig) -> some View {
        OptionSection(title: Text("Agent")) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ns.availableAgents) { agent in
                        agentChoice(agent, isSelected: agent == ns.selectedAgent) {
                            ns.onSelectAgent(agent)
                            // Reload this agent's options + working dir in place.
                            options.prepare(agentType: agent, workingDir: ns.selectedFolder?.path)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // Animate the selection ring + scale pop when the chosen agent
                // changes (the "transition" the picker was missing).
                .animation(.snappy(duration: 0.26), value: ns.selectedAgent)
            }
            // Soft-fade both edges instead of letting chips spill past the card's
            // rounded background. The mask also clips the row to its bounds, so a
            // chip dragged off-screen dissolves at the edge rather than overhanging
            // the glass (the old `.scrollClipDisabled()` let it overhang).
            .mask(Self.edgeFadeMask)
        }
    }

    /// A horizontal clear→opaque→clear gradient: opaque across the middle so chips
    /// read fully, fading the last few points at each edge for a soft scroll-off.
    private static let edgeFadeMask = LinearGradient(
        stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.05),
            .init(color: .black, location: 0.95),
            .init(color: .clear, location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    private func agentChoice(_ agent: AgentType, isSelected: Bool, onSelect: @escaping () -> Void) -> some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                AgentAvatar(agent: agent, size: 46)
                    .overlay(Circle().strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2))
                    // The selected agent sits at full size; the rest recede slightly,
                    // so switching animates a gentle pop (paired with the ring).
                    .scaleEffect(isSelected ? 1 : 0.92)
                Text(agent.shortName)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(agent.displayName)\(isSelected ? ", selected" : "")")
    }

    // MARK: - Workspace (folder + branch in one card)

    /// Folder + branch grouped in a single card. The folder is the switchable
    /// draft picker when `newSession` is set, else a read-only row (an existing
    /// conversation is bound to its working dir); the branch row is switchable in
    /// both cases.
    private func workspaceSection(newSession ns: NewSessionAgentConfig?, branch: SessionBranchConfig) -> some View {
        OptionSection(title: Text("Workspace")) {
            if let ns {
                folderMenuRow(ns)
            } else {
                folderReadOnlyRow(branch)
            }
            rowSeparator
            branchLinkRow(branch)
        }
    }

    private func folderMenuRow(_ ns: NewSessionAgentConfig) -> some View {
        let binding = Binding<Int?>(
            get: { ns.selectedFolder?.id },
            set: { id in
                guard let folder = ns.availableFolders.first(where: { $0.id == id }) else { return }
                ns.onSelectFolder(folder)
                options.prepare(agentType: ns.selectedAgent, workingDir: folder.path)
            }
        )
        return Menu {
            Picker("Folder", selection: binding) {
                ForEach(ns.availableFolders) { folder in
                    Label(folder.name, systemImage: "folder").tag(Optional(folder.id))
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    if let n = ns.selectedFolder?.name {
                        Text(verbatim: n)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    } else {
                        Text("Choose a folder")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    if let path = ns.selectedFolder?.path {
                        Text(path)
                            .font(.mono(10))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    /// The session's folder, read-only — an existing conversation is bound to its
    /// working dir, so the folder can't be switched (only the branch can).
    private func folderReadOnlyRow(_ branch: SessionBranchConfig) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(branch.folderName ?? "—")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let path = branch.folderPath {
                    Text(path)
                        .font(.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The current branch as a row that pushes the full branch picker. Disabled
    /// while the agent is responding (switching the working tree mid-turn would
    /// disrupt it — consistent with the other options being locked when busy).
    private func branchLinkRow(_ branch: SessionBranchConfig) -> some View {
        NavigationLink {
            BranchPickerView(config: branch, dismissSheet: dismissSheet)
        } label: {
            // Mirror the folder row's two-line layout (label + mono value) so the
            // two rows in the Workspace card are exactly the same height.
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(isBusy ? Theme.textTertiary : Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Branch")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Group {
                        if let c = branch.current {
                            Text(verbatim: c)
                        } else {
                            Text("Select a branch")
                        }
                    }
                        .font(.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
    }

    // MARK: - States

    private func loadingRow(_ message: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(Theme.accent)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .codegGlassEffect(in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { options.load() }
                .codegGlassButtonStyle()
                .tint(Theme.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.danger.opacity(0.4))
    }

    @ViewBuilder
    private var selectors: some View {
        let configOptions = options.snapshot?.configOptions ?? []
        let modes = options.snapshot?.modes
        let hasConfig = !configOptions.isEmpty
        let hasModes = !(modes?.availableModes.isEmpty ?? true)

        // Modes and config options are mutually exclusive surfaces, exactly as the
        // web client gates them (`showModeSelector = hasModes && !hasConfigOptions`).
        // When an agent exposes config options, its mode is represented there, so
        // showing the Mode section too would duplicate it.
        if hasModes, !hasConfig, let modes {
            OptionSection(title: Text("Mode")) {
                ForEach(Array(modes.availableModes.enumerated()), id: \.element.id) { index, mode in
                    if index > 0 { rowSeparator }
                    OptionRow(
                        title: mode.name,
                        subtitle: mode.description,
                        isSelected: options.selectedModeId == mode.id,
                        isApplying: options.applying.contains("mode") && options.selectedModeId == mode.id,
                        disabled: isBusy || options.applying.contains("mode"),
                        action: { options.selectMode(mode.id) }
                    )
                }
            }
        }

        ForEach(configOptions) { option in
            configSection(option)
        }
    }

    /// One config option. Renders grouped options (group label + its options) when
    /// `groups` is non-empty, ELSE the flat options — never both, matching the
    /// web's `groups.length > 0 ? groups : options` ternary (the source of the
    /// duplicate rows when both were rendered).
    @ViewBuilder
    private func configSection(_ option: SessionConfigOption) -> some View {
        let groups = option.kind.selectGroups ?? []
        let flat = option.kind.selectOptions ?? []
        if !groups.isEmpty {
            OptionSection(title: Text(verbatim: option.name)) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                    if groupIndex > 0 { rowSeparator }
                    groupHeader(group.name)
                    ForEach(Array(group.options.enumerated()), id: \.element.id) { index, choice in
                        if index > 0 { rowSeparator }
                        optionRow(option: option, choice: choice)
                    }
                }
            }
        } else if !flat.isEmpty {
            OptionSection(title: Text(verbatim: option.name)) {
                ForEach(Array(flat.enumerated()), id: \.element.id) { index, choice in
                    if index > 0 { rowSeparator }
                    optionRow(option: option, choice: choice)
                }
            }
        }
    }

    private func optionRow(option: SessionConfigOption, choice: SessionConfigSelectOption) -> some View {
        OptionRow(
            title: choice.name,
            subtitle: choice.description,
            isSelected: options.selectedConfig[option.id] == choice.value,
            isApplying: options.applying.contains(option.id) && options.selectedConfig[option.id] == choice.value,
            disabled: isBusy || options.applying.contains(option.id),
            action: { options.selectConfig(optionId: option.id, valueId: choice.value) }
        )
    }

    private func groupHeader(_ name: String) -> some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.75)
            .padding(.leading, 14)
    }

    /// Takes a `Text` so callers pass a localized literal (`Text("…")`) for fixed
    /// chrome or `Text(verbatim:)` for dynamic server notices.
    private func hint(_ text: Text, tint: Color = Theme.textTertiary) -> some View {
        text
            .font(.caption)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A titled group of option rows in a glass container.
struct OptionSection<Content: View>: View {
    /// A `Text` so callers localize fixed section names (`Text("Agent")`) but pass
    /// dynamic server option names verbatim (`Text(verbatim: option.name)`).
    let title: Text
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            title
                .textCase(.uppercase)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .codegGlassEffect(in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .hairlineBorder(Theme.Radius.md)
        }
    }
}

/// A single selectable option row (radio-style), with a trailing check or spinner.
private struct OptionRow: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let isApplying: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isApplying {
                    ProgressView().controlSize(.small)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && !isSelected && !isApplying ? 0.5 : 1)
    }
}
