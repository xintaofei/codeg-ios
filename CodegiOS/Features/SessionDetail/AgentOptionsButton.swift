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

/// The agent chip in the session detail's navigation bar (trailing): the agent's
/// glyph followed by its current settings at a glance — "Opus 5.5 / High /
/// Plan", codeg 0.44's merged settings chip (`session-settings-picker.tsx`).
/// Tapping opens a sheet that auto-loads the agent's Mode + config selectors; for
/// a new-session draft it additionally hosts the Agent + Folder pickers
/// (`newSession`).
///
/// The summary is read with ``AgentOptionsModel/refreshSummary(agentType:workingDir:)``,
/// which never spawns a probe agent: until a catalog exists (a live session, or
/// the sheet having been opened once) the chip is just the glyph, as before.
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
    @Environment(\.locale) private var locale
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Re-read the summary when the agent or folder changes (draft pickers) and
    /// when a turn settles — the agent may have moved its own mode (plan exit).
    private struct SummaryTrigger: Hashable {
        let agentType: AgentType
        let workingDir: String?
        let isBusy: Bool
    }

    /// The settings to summarize — only while the model holds THIS agent's
    /// catalog, so a draft that just switched agents shows the bare glyph rather
    /// than the previous agent's values.
    private var settings: [SessionSetting] {
        guard options.agentType == agentType else { return [] }
        return options.sessionSettings(modeTitle: localized("Mode"))
    }

    /// The summary's width cap. A compact-width navigation bar shares its row
    /// with the back button, the title and the actions menu, so the chip stays
    /// small there and long values truncate. (The web drops the values in a
    /// composer narrower than 16rem; a phone always has room for a short one.)
    private var summaryMaxWidth: CGFloat { sizeClass == .regular ? 240 : 112 }

    var body: some View {
        let settings = self.settings
        let parts = SessionSettings.summaryParts(settings)
        // iOS 26 already wraps a toolbar button in its own Liquid Glass shape, so
        // the bare brand glyph is all that's needed — `AgentAvatar`'s tinted disc +
        // ring would sit *inside* that glass as a redundant second border. With
        // values beside it the system glass simply becomes a capsule.
        Button { showSheet = true } label: {
            HStack(spacing: 6) {
                AgentIcon(agent: agentType)
                    .frame(width: 22, height: 22)
                if !parts.isEmpty {
                    SessionSettingsSummary(parts: parts)
                        .frame(maxWidth: summaryMaxWidth, alignment: .leading)
                }
            }
            .padding(.horizontal, parts.isEmpty ? 0 : 4)
            .accessibilityElement(children: .ignore)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(newSession == nil ? Text("Agent settings") : Text("Choose agent, folder, and options"))
        // Every setting, including the ones the visible label leaves out (a
        // `default` value, a switch that is off).
        .accessibilityValue(Text(verbatim: SessionSettings.accessibilityValue(
            settings, on: localized("On"), off: localized("Off")
        )))
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
        .task(id: SummaryTrigger(agentType: agentType, workingDir: workingDir, isBusy: isBusy)) {
            // The sheet runs its own (fuller) load; mid-turn the values are about
            // to move anyway.
            guard !showSheet, !isBusy else { return }
            options.refreshSummary(agentType: agentType, workingDir: workingDir)
        }
    }

    /// A catalog string in the in-app language (`String(localized:)` alone
    /// follows the device language, not the Language setting).
    private func localized(_ key: String.LocalizationValue) -> String {
        var resource = LocalizedStringResource(key)
        resource.locale = locale
        return String(localized: resource)
    }
}

/// The chip's values joined by "/", on one line. A short value
/// (``SessionSettings/isShortSummary(_:)``) never truncates; longer ones share
/// the squeeze, and whatever still doesn't fit is clipped at the trailing edge
/// rather than drawn past it (the web's `overflow-hidden`).
private struct SessionSettingsSummary: View {
    let parts: [String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text(verbatim: "/")
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 3)
                        .fixedSize()
                }
                if SessionSettings.isShortSummary(part) {
                    Text(verbatim: part).fixedSize()
                } else {
                    Text(verbatim: part)
                        .truncationMode(.tail)
                        .frame(minWidth: 36, alignment: .leading)
                }
            }
        }
        .lineLimit(1)
        .font(.footnote.weight(.medium))
        .foregroundStyle(Theme.textSecondary)
        .clipped()
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
                Text(agent.isBuiltin ? agent.shortName : agent.label)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(agent.label)\(isSelected ? ", selected" : "")")
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { options.load() }
                .buttonStyle(.glass)
                .tint(Theme.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.danger.opacity(0.4))
    }


    /// The agent's settings in the button's order — model, effort, mode, the
    /// rest, then the switches (``SessionSettings/build(configOptions:modes:currentModeId:modeTitle:)``).
    ///
    /// The builder applies the same gates this sheet always had: only options
    /// this build can draw (a kind newer than this app would otherwise suppress
    /// the Mode section for nothing — the server strips only the kinds IT can't
    /// decode), and the legacy Mode list only when the agent has no config
    /// options (the web's `showModeSelector = hasModes && !hasConfigOptions`).
    @ViewBuilder
    private var selectors: some View {
        ForEach(options.sessionSettings(modeTitle: "Mode")) { setting in
            settingSection(setting)
        }
    }

    /// The section title: the localized "Mode" for the legacy list, the agent's
    /// own (verbatim) name for a config option.
    private func sectionTitle(_ setting: SessionSetting) -> Text {
        setting.target == .mode ? Text("Mode") : Text(verbatim: setting.title)
    }

    /// One setting. A switch is one row; a searchable list (more than
    /// ``SessionSettings/searchThreshold`` values) is a row that pushes a
    /// searchable picker, so a long model list never renders inline; anything
    /// shorter lists its values in place, under group headers when it has named
    /// groups — never the groups AND the flat list (the web's `groups.length > 0
    /// ? groups : options`, the source of duplicate rows when both were drawn).
    ///
    /// The web's segmented control for a short select is not ported: radio rows
    /// with descriptions read better at phone width.
    @ViewBuilder
    private func settingSection(_ setting: SessionSetting) -> some View {
        switch setting.control {
        case .toggle(let isOn, let onValue, let offValue):
            OptionSection(title: sectionTitle(setting)) {
                toggleRow(setting, isOn: isOn, onValue: onValue, offValue: offValue)
            }
        case .choice(let choice) where choice.searchable:
            OptionSection(title: sectionTitle(setting)) {
                listLinkRow(setting, choice: choice)
            }
        case .choice(let choice):
            OptionSection(title: sectionTitle(setting)) {
                ForEach(Array(choice.groups.enumerated()), id: \.element.key) { groupIndex, group in
                    if groupIndex > 0 { rowSeparator }
                    if let name = group.name { OptionGroupHeader(name: name) }
                    ForEach(Array(group.options.enumerated()), id: \.element.id) { index, value in
                        if index > 0 { rowSeparator }
                        SettingValueRow(options: options, setting: setting, choice: choice, value: value, isBusy: isBusy)
                    }
                }
            }
        }
    }

    /// The switch behind a boolean option or an on/off select. A flip sends the
    /// agent's own value for on or off through the same string-valued path as a
    /// select — see ``SessionConfigKind``.
    private func toggleRow(_ setting: SessionSetting, isOn: Bool, onValue: String, offValue: String) -> some View {
        let applying = options.applying.contains(setting.target)
        return BooleanOptionRow(
            name: setting.title,
            title: setting.description.flatMap { $0.isEmpty ? nil : $0 },
            isOn: isOn,
            isApplying: applying,
            disabled: isBusy || applying,
            set: { on in options.apply(setting.target, value: on ? onValue : offValue) }
        )
    }

    /// A long list's row: the current value, pushing the searchable picker.
    private func listLinkRow(_ setting: SessionSetting, choice: SessionChoice) -> some View {
        NavigationLink {
            SettingListPicker(options: options, settingKey: setting.key, isBusy: isBusy)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: choice.currentLabel)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let description = choice.currentDescription, !description.isEmpty {
                        Text(verbatim: description)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if options.applying.contains(setting.target) {
                    ProgressView().controlSize(.small)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .hairlineBorder(Theme.Radius.md)
        }
    }
}

/// The row behind a boolean config option: a switch, with the option's
/// description as its label when it has one (the option's NAME is already the
/// section header above it). While an apply is in flight the switch is replaced
/// by a spinner, matching what a select's row does.
private struct BooleanOptionRow: View {
    /// The option's own name. It's already the section header, so it isn't drawn
    /// again — it's what VoiceOver announces, since the switch's visible label is
    /// the description (or nothing at all).
    let name: String
    let title: String?
    let isOn: Bool
    let isApplying: Bool
    let disabled: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let title {
                    Text(verbatim: title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Enabled")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isApplying {
                ProgressView().controlSize(.small)
            } else {
                Toggle("", isOn: Binding(get: { isOn }, set: set))
                    .labelsHidden()
                    .tint(Theme.accent)
                    .disabled(disabled)
                    .accessibilityLabel(Text(verbatim: name))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .opacity(disabled && !isApplying ? 0.5 : 1)
    }
}

/// A value row of a select setting, wired to the model: checked when it is the
/// current value, spinning while that selector applies, badged when the agent
/// recommends it (`recommended_value`, codex-acp 1.11.0+ / claude-agent-acp
/// 0.76.0+) — a claim independent of the checkmark, so both can land on the
/// same row or on different ones.
private struct SettingValueRow: View {
    let options: AgentOptionsModel
    let setting: SessionSetting
    let choice: SessionChoice
    let value: SessionConfigSelectOption
    let isBusy: Bool

    var body: some View {
        let isSelected = value.value == choice.currentValue
        let applying = options.applying.contains(setting.target)
        OptionRow(
            title: value.name,
            subtitle: value.description,
            isRecommended: value.value == choice.recommendedValue,
            isSelected: isSelected,
            isApplying: applying && isSelected,
            disabled: isBusy || applying,
            action: { options.apply(setting.target, value: value.value) }
        )
    }
}

/// A provider / server group's label above its rows.
private struct OptionGroupHeader: View {
    let name: String

    var body: some View {
        Text(verbatim: name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

private struct OptionRowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.75)
            .padding(.leading, 14)
    }
}

/// A long setting's values — the model list, or any select past
/// ``SessionSettings/searchThreshold`` values — on their own page with a search
/// field (the web's `ModelOptionList`). Matches the display name OR the value id
/// (``ModelOptionGroups/filter(_:query:)``), so a provider prefix stripped from
/// the labels still finds its models. Lazy, since a provider catalog can run to
/// hundreds of rows, and opened on the current value. A pick applies at once and
/// the page stays, like the web popover.
///
/// Reads the setting from the model by key on every render, so the checkmark
/// follows a pick (and its reconciliation) live.
private struct SettingListPicker: View {
    let options: AgentOptionsModel
    let settingKey: String
    let isBusy: Bool

    @State private var query = ""

    var body: some View {
        let setting = options.sessionSettings(modeTitle: "Mode").first { $0.key == settingKey }
        let choice = setting?.choice
        let groups = choice.map { ModelOptionGroups.filter($0.groups, query: query) } ?? []
        ZStack {
            CodegBackground()
            if let setting, let choice {
                ScrollViewReader { proxy in
                    ScrollView {
                        if groups.isEmpty {
                            Text(choice.isModel ? "No models found" : "No options found")
                                .font(.callout)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(groups.enumerated()), id: \.element.key) { groupIndex, group in
                                    if groupIndex > 0 { OptionRowSeparator() }
                                    if let name = group.name { OptionGroupHeader(name: name) }
                                    ForEach(Array(group.options.enumerated()), id: \.element.id) { index, value in
                                        if index > 0 { OptionRowSeparator() }
                                        SettingValueRow(options: options, setting: setting, choice: choice, value: value, isBusy: isBusy)
                                            .id(Self.rowID(group: group.key, value: value.value))
                                    }
                                }
                            }
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                            .hairlineBorder(Theme.Radius.md)
                            .padding(16)
                        }
                    }
                    .onAppear {
                        // Open on the row the user came to change: a long list
                        // opened at its top would hide it.
                        guard let group = choice.groups.first(where: { $0.options.contains { $0.value == choice.currentValue } })
                        else { return }
                        proxy.scrollTo(Self.rowID(group: group.key, value: choice.currentValue), anchor: .center)
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: setting?.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(choice?.isModel == true ? "Search models" : "Search options")
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
    }

    /// Keyed by group as well: the same value may sit in two server groups.
    private static func rowID(group: String, value: String) -> String { "\(group)\u{1F}\(value)" }
}

/// A single selectable option row (radio-style), with a trailing check or spinner.
private struct OptionRow: View {
    let title: String
    let subtitle: String?
    var isRecommended = false
    let isSelected: Bool
    let isApplying: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                        if isRecommended {
                            // Fixed so a long model name wraps instead of
                            // squeezing the badge away.
                            Text("Recommended")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(Theme.surfaceStroke))
                                .fixedSize()
                        }
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
