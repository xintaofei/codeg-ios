import SwiftUI

/// Per-agent settings detail. Hosts the shared sections (header, enabled, preflight
/// + fixes, install/version, native-config escape hatch) and dispatches to a
/// per-agent-type structured config section. Navigates by `AgentType` and reads the
/// LIVE agent from the model, so a save/install reload is reflected without a stale
/// snapshot. The editable form lives in a single `AgentDraft` (@State) that the
/// per-type sections bind to; secrets are in-memory only and round-trip through the
/// dedicated endpoints.
struct AgentDetailView: View {
    let model: AgentsSettingsModel
    let agentType: AgentType
    let client: CodegClient?

    @State private var draft: AgentDraft
    @State private var enabled: Bool
    @State private var togglingEnabled = false
    @State private var providers: [ModelProviderInfo] = []
    @State private var preflight: PreflightResult?
    @State private var preflightLoading = true
    @State private var isSaving = false
    @State private var saveError: String?

    // Custom-version install + uninstall confirmation
    @State private var showCustomVersion = false
    @State private var customVersionText = ""
    @State private var showUninstallConfirm = false
    @State private var pendingUninstall: AgentInstallAction?
    // Advanced (raw native config) — collapsed by default; it's an escape hatch.
    @State private var showNativeConfig = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(model: AgentsSettingsModel, agentType: AgentType, client: CodegClient?) {
        self.model = model
        self.agentType = agentType
        self.client = client
        let agent = model.agent(agentType)
        _draft = State(initialValue: agent.map { AgentDraft(agent: $0) } ?? AgentDraft())
        _enabled = State(initialValue: agent?.enabled ?? false)
    }

    private var agent: AcpAgentInfo? { model.agent(agentType) }
    private var agentProviders: [ModelProviderInfo] { providers.filter { $0.agentType == agentType } }
    private var isInstalling: Bool { model.installing.contains(agentType) }

    /// Kimi & Pi drive their own dedicated backends and carry their own save
    /// button(s), so — like Hermes' raw editor — they hide the host "Save" and the
    /// generic native-config escape hatch.
    private var isSelfContainedAgent: Bool { agentType == .kimiCode || agentType == .pi }
    private var hostSaveShown: Bool { !isSelfContainedAgent }

    /// uv runtime readiness for the version row (uvx agents only). Derived from the
    /// preflight uv check; absent check → treated ready.
    private var uvReady: Bool {
        guard let preflight else { return true }
        for c in preflight.checks where c.checkId.lowercased().contains("uv") || c.label.lowercased().contains("uv") {
            return c.isOK
        }
        return true
    }

    var body: some View {
        ZStack {
            CodegBackground()
            if let agent {
                content(agent)
            } else {
                EmptyStateView(icon: "cpu", title: "Agent Unavailable", message: "This agent is no longer registered on the server.")
            }
        }
        .navigationTitle(agent?.name ?? agentType.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Kimi & Pi own their save buttons inside their panels (dedicated
            // backends, multiple independent saves) — no single host "Save".
            if hostSaveShown {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .tint(Theme.accent)
                        .disabled(isSaving || togglingEnabled || isInstalling || agent == nil)
                }
            }
        }
        .task {
            await loadPreflight()
            providers = (try? await client?.listModelProviders()) ?? []
        }
        // Re-run preflight when an install finishes so checks + version reconcile.
        .onChange(of: isInstalling) { wasInstalling, nowInstalling in
            if wasInstalling && !nowInstalling { Task { await loadPreflight(force: true) } }
        }
        .alert("Couldn’t Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
        .alert("Install a specific version", isPresented: $showCustomVersion) {
            TextField("e.g. 1.2.3", text: $customVersionText)
                .textInputAutocapitalization(.never).autocorrectionDisabled(true)
            Button("Install") { confirmCustomVersion() }
                .disabled(!AgentVersion.isValidCustom(customVersionText))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a dotted version (a leading “v” is fine). Dist-tags like “latest” aren’t allowed.")
        }
        .confirmationDialog("Uninstall \(agent?.name ?? "agent")?", isPresented: $showUninstallConfirm, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                if let action = pendingUninstall { runVersion(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the locally installed binary. You can reinstall it any time.")
        }
    }

    private func content(_ agent: AcpAgentInfo) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // The hero header carries identity + the Enabled toggle. Install/
                // version + preflight come next (know it's installed and healthy
                // before tuning), then the editable config.
                header(agent)
                installSection(agent)
                preflightSection
                typeConfigSection(agent)
                // Hermes' config_json is a read-only backend projection, not a raw
                // file — its structured form is the only editor. Kimi & Pi own their
                // own raw/native editors inside their panels.
                if agentType != .hermes && !isSelfContainedAgent { nativeConfigSection }
                if (agent.distributionType ?? "") == "binary" { clearCacheButton(agent) }
            }
            .padding(.horizontal, Theme.Layout.screenHMargin)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
    }

    // MARK: Header

    private func header(_ agent: AcpAgentInfo) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    AgentAvatar(agent: agent.agentType, size: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(agent.name)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        AgentStatusPill(agent: agent)
                    }
                    Spacer(minLength: 8)
                    enabledToggle(agent)
                }
                if !agent.description.isEmpty {
                    Text(agent.description)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let path = agent.configFilePath, !path.isEmpty {
                    Label(path, systemImage: "doc.text")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if !agent.available {
                    Label("Not available on this server.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.danger)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Enabled (lives in the hero header — applied immediately)

    private func enabledToggle(_ agent: AcpAgentInfo) -> some View {
        HStack(spacing: 6) {
            if togglingEnabled { ProgressView().controlSize(.small).tint(Theme.accent) }
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { on in
                    enabled = on
                    togglingEnabled = true
                    Task {
                        switch await model.setEnabled(agent, on) {
                        case .applied: break
                        case .noChange: enabled = !on
                        case .failed(let message): enabled = !on; saveError = message
                        }
                        togglingEnabled = false
                    }
                }
            ))
            .labelsHidden()
            .tint(Theme.accent)
            .accessibilityLabel("Enabled")
            .disabled(togglingEnabled || isSaving || isInstalling || !agent.available)
        }
    }

    // MARK: Per-type structured config (filled in by B6/B7)

    @ViewBuilder
    private func typeConfigSection(_ agent: AcpAgentInfo) -> some View {
        AgentConfigSection(agentType: agentType, draft: $draft, providers: agentProviders,
                           model: model, agent: agent, client: client)
    }

    // MARK: Install / version

    @ViewBuilder
    private func installSection(_ agent: AcpAgentInfo) -> some View {
        if let check = AgentVersion.check(agent, uvReady: uvReady) {
            // Primary = the constructive action (Install/Upgrade); the rest
            // (Uninstall, Custom install) go in an overflow menu so the row never
            // wraps to a ragged second line.
            let primary = check.actions.first { $0.action.isInstall || $0.action.isUpgrade }
            let secondary = check.actions.filter { $0.id != primary?.id }
            let glyph = versionGlyph(check.status)
            let parts = versionParts(agent, check)
            let upgradeable = primary?.action.isUpgrade == true
            EditorSection(title: "Version") {
                VStack(spacing: 0) {
                    // Versions as structured stats (read from the agent, not the
                    // bundled prose) so the row reads as data, not a wrapping sentence.
                    HStack(alignment: .top, spacing: 32) {
                        versionStat("Installed", parts.installed)
                        versionStat("Latest", parts.latest, highlight: upgradeable)
                        Spacer(minLength: 0)
                        if isInstalling { ProgressView().controlSize(.small).tint(Theme.accent).padding(.top, 2) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    Divider().overlay(Theme.hairline)

                    // The status sentence (version prefix stripped) with its glyph.
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: glyph.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(glyph.color)
                            .padding(.top, 1)
                        Text(parts.note)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if primary != nil || !secondary.isEmpty {
                        Divider().overlay(Theme.hairline)
                        versionActions(primary: primary, secondary: secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    /// Two-column version readout: a small uppercase label over the value
    /// (monospaced). `highlight` tints the value (used on "Latest" when an upgrade
    /// is available) to draw the eye to the actionable number.
    private func versionStat(_ label: LocalizedStringKey, _ value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).textCase(.uppercase)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .tracking(0.5)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospaced()
                .foregroundStyle(highlight ? Theme.accent : Theme.textPrimary)
        }
    }

    /// Splits the synthesized `check.message` ("Remote: R · Local: L. <note>") into
    /// a clean Installed/Latest pair (from the agent, so versions render as data)
    /// and the trailing status sentence. Falls back to the full message if the
    /// expected prefix isn't present.
    private func versionParts(_ agent: AcpAgentInfo, _ check: AgentVersionCheck)
        -> (installed: String, latest: String, note: String) {
        let installed = agent.installedVersion ?? "—"
        let latest = agent.registryVersion ?? "—"
        let prefix = "Remote: \(agent.registryVersion ?? "unknown") · Local: \(agent.installedVersion ?? "Not installed")"
        var note = check.message
        if note.hasPrefix(prefix) {
            var rest = Substring(note.dropFirst(prefix.count))
            while let f = rest.first, f == "." || f == " " { rest = rest.dropFirst() }
            if !rest.isEmpty { note = String(rest) }
        }
        return (installed, latest, note)
    }

    @ViewBuilder
    private func versionActions(primary: AgentVersionAction?, secondary: [AgentVersionAction]) -> some View {
        if let primary {
            HStack(spacing: 10) {
                Button { runVersion(primary.action) } label: {
                    Text(primary.label).fontWeight(.semibold)
                        .padding(.horizontal, 18).padding(.vertical, 5)
                }
                .codegGlassButtonStyle(prominent: true).tint(Theme.accent)
                .disabled(isInstalling || primary.disabled)
                Spacer(minLength: 0)
                if !secondary.isEmpty { versionMenu(secondary, iconOnly: true) }
            }
        } else if !secondary.isEmpty {
            HStack { versionMenu(secondary, iconOnly: false); Spacer(minLength: 0) }
        }
    }

    @ViewBuilder
    private func versionMenu(_ actions: [AgentVersionAction], iconOnly: Bool) -> some View {
        Menu {
            ForEach(actions) { a in
                Button(role: a.action.isUninstall ? .destructive : nil) { runVersion(a.action) } label: {
                    Label(a.label, systemImage: a.action.isUninstall ? "trash" : "arrow.down.circle")
                }
            }
        } label: {
            if iconOnly {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 46, height: 34)
            } else {
                Label("Manage", systemImage: "ellipsis.circle")
                    .font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 7)
            }
        }
        .codegGlassButtonStyle().tint(iconOnly ? Theme.textSecondary : Theme.accent)
        .accessibilityLabel(iconOnly ? "More version actions" : "Manage version")
        .disabled(isInstalling)
    }

    private func versionGlyph(_ status: AgentVersionCheck.Status) -> (symbol: String, color: Color) {
        switch status {
        case .pass: return ("checkmark.circle.fill", Theme.accent)
        case .warn: return ("exclamationmark.triangle.fill", Theme.warning)
        case .fail: return ("xmark.circle.fill", Theme.danger)
        }
    }

    // MARK: Preflight + fixes

    @ViewBuilder
    private var preflightSection: some View {
        EditorSection(title: "Preflight") {
            VStack(spacing: 0) {
                if preflightLoading {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                        Text("Checking…").font(.subheadline).foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                } else if let preflight {
                    if preflight.checks.isEmpty {
                        Text(preflight.passed ? "All checks passed." : "No checks reported.")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                    }
                    ForEach(Array(preflight.checks.enumerated()), id: \.element.id) { index, check in
                        if index > 0 { Divider().overlay(Theme.hairline) }
                        preflightRow(check)
                    }
                    Divider().overlay(Theme.hairline)
                    rerunRow
                } else {
                    Button { Task { await loadPreflight(force: true) } } label: {
                        Text("Run Preflight")
                            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.horizontal, 16).padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func preflightRow(_ check: PreflightCheck) -> some View {
        let glyph = checkGlyph(check)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: glyph.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(glyph.color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(check.label).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    if !check.message.isEmpty {
                        Text(check.message).font(.caption).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            // Drop pure link fixes (e.g. "Open docs") — they're not actionable
            // remediations and just clutter the check row.
            let fixes = (check.fixes ?? []).filter { $0.kind != .openURL }
            if !fixes.isEmpty {
                FlowFixButtons(fixes: fixes, disabled: isInstalling) { handleFix($0) }
                    .padding(.leading, 34)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var rerunRow: some View {
        Button { Task { await loadPreflight(force: true) } } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.clockwise")
                Text("Re-run checks")
                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
            .contentShape(Rectangle())
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }

    // MARK: Native config (escape hatch)

    private var nativeConfigBinding: Binding<String> {
        switch agentType {
        case .codex: return $draft.codexConfigTomlText
        case .grok: return $draft.grokConfigTomlText
        case .cursor: return $draft.cursorCliConfigText
        case .hermes: return $draft.hermesConfigYaml
        default: return $draft.configText
        }
    }
    private var nativeConfigLabel: String {
        switch agentType {
        case .codex, .grok: return "config.toml"
        case .cursor: return "cli-config.json"
        case .hermes: return "config.yaml"
        default: return "config.json"
        }
    }

    private var nativeConfigSection: some View {
        EditorSection(title: "Advanced", footer: "Raw \(nativeConfigLabel). Edits here override the fields above on save.") {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showNativeConfig.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "curlybraces")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Native config").font(.subheadline).foregroundStyle(Theme.textPrimary)
                            Text(nativeConfigLabel).font(.caption.monospaced()).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(showNativeConfig ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                .buttonStyle(.plain)

                if showNativeConfig {
                    Divider().overlay(Theme.hairline)
                    TextEditor(text: nativeConfigBinding)
                        .font(.mono(12))
                        .frame(minHeight: 200)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.hairline))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .padding(16)
                }
            }
        }
    }

    private func clearCacheButton(_ agent: AcpAgentInfo) -> some View {
        Button(role: .destructive) {
            Task { await model.clearCache(agent) }
        } label: {
            Label("Clear Binary Cache", systemImage: "trash").frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .codegGlassButtonStyle()
        .tint(Theme.danger)
        .disabled(isInstalling)
    }

    // MARK: Actions

    private func checkGlyph(_ check: PreflightCheck) -> (symbol: String, color: Color) {
        if check.isOK { return ("checkmark.circle.fill", Theme.accent) }
        if check.isWarning { return ("exclamationmark.triangle.fill", Theme.warning) }
        return ("xmark.circle.fill", Theme.danger)
    }

    private func loadPreflight(force: Bool = false) async {
        guard let client else { preflightLoading = false; return }
        preflightLoading = true
        preflight = try? await client.agentPreflight(agentType: agentType, forceRefresh: force)
        preflightLoading = false
    }

    /// A synthetic version-row action: uninstall confirms, custom-install prompts,
    /// everything else runs immediately.
    private func runVersion(_ action: AgentInstallAction) {
        switch action {
        case .customInstall:
            customVersionText = agent?.registryVersion ?? ""
            showCustomVersion = true
        case .uninstallBinary, .uninstallNpx:
            pendingUninstall = action
            showUninstallConfirm = true
        default:
            Task { _ = await model.runInstall(agentType, action) }
        }
    }

    private func confirmCustomVersion() {
        let version = customVersionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentVersion.isValidCustom(version) else { return }
        let upgrade: AgentInstallAction = (agent?.distributionType ?? "") == "binary" ? .upgradeBinary : .upgradeNpx
        Task { _ = await model.runInstall(agentType, upgrade, customVersion: version) }
    }

    private func handleFix(_ fix: FixAction) {
        switch fix.kind {
        case .openURL:
            if let url = URL(string: fix.payload) { openURL(url) }
        case .installUv:
            Task { _ = await model.runUvInstall(agentType) }
        case .redownloadBinary:
            Task { _ = await model.runInstall(agentType, .upgradeBinary) }
        case .retryConnection, .openAgentsSettings:
            Task { await loadPreflight(force: true) }
        case .installOpenCodePlugins:
            saveError = "Installing OpenCode plugins isn’t available on iOS yet — use the desktop app."
        case .unknown:
            break
        }
    }

    private func save() {
        guard agent != nil else { return }
        // Block a model_provider-mode save with no provider chosen (web parity) —
        // otherwise we'd persist an unlinked, credential-less agent.
        if AgentConfig.missingModelProvider(agentType, draft) {
            saveError = "Choose a model provider before saving."
            return
        }
        // A self-hosted CodeBuddy needs a valid endpoint before we persist the env.
        if AgentConfig.missingCodeBuddyBaseUrl(agentType, draft) {
            saveError = "Enter a valid http(s) URL for the self-hosted deployment."
            return
        }
        // API-key mode with no key would persist a credential-less auth mode.
        if AgentConfig.missingCursorApiKey(agentType, draft) {
            saveError = "Enter your Cursor API key, or switch to Official Subscription."
            return
        }
        isSaving = true
        Task {
            do {
                if agentType == .hermes {
                    // Structured save; then rebuild from the fresh projection (A3) —
                    // never trust the stale local draft after a hermes save.
                    try await model.saveHermesConfig(AgentConfig.hermesStructuredBody(draft))
                    if let fresh = model.agent(.hermes) { draft = AgentDraft(agent: fresh) }
                } else {
                    try await model.saveAgentConfig(agentType, draft: draft)
                }
                isSaving = false
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - Per-type structured config dispatch (cases filled in by B6/B7)

/// Routes to the per-agent structured form. Any field a form doesn't surface is
/// still reachable via the host's native-config editor (nothing is unreachable).
struct AgentConfigSection: View {
    let agentType: AgentType
    @Binding var draft: AgentDraft
    let providers: [ModelProviderInfo]
    /// Passed through for the self-contained agents (Kimi / Pi), which own their
    /// state + save buttons and talk to the server directly rather than via the
    /// shared draft + host "Save".
    let model: AgentsSettingsModel
    let agent: AcpAgentInfo
    let client: CodegClient?

    var body: some View {
        switch agentType {
        case .claudeCode: ClaudeConfigSection(draft: $draft, providers: providers)
        case .codex:      CodexConfigSection(draft: $draft, providers: providers)
        case .gemini:     GeminiConfigSection(draft: $draft, providers: providers)
        case .openClaw:   OpenClawConfigSection(draft: $draft)
        case .cline:      ClineConfigSection(draft: $draft)
        case .openCode:   OpenCodeConfigSection(draft: $draft)
        case .hermes:     HermesConfigSection(draft: $draft)
        case .codeBuddy:  CodeBuddyConfigSection(draft: $draft)
        case .grok:       GrokConfigSection(draft: $draft)
        case .cursor:     CursorConfigSection(draft: $draft, client: client)
        case .kimiCode:   KimiConfigSection(model: model, agent: agent, client: client)
        case .pi:         PiConfigSection(model: model, agent: agent, client: client)
        }
    }
}

// MARK: - Small button rows

private struct FlowFixButtons: View {
    let fixes: [FixAction]
    let disabled: Bool
    let onTap: (FixAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(fixes) { fix in
                Button { onTap(fix) } label: {
                    Text(fix.label).font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
                }
                .codegGlassButtonStyle()
                .tint(Theme.accent)
                .disabled(disabled)
            }
            Spacer(minLength: 0)
        }
    }
}

