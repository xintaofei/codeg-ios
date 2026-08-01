import SwiftUI

/// Self-contained Pi settings panel (ported from the web `PiConfigPanel`). Pi has
/// three independent stores — runtime (which pi binary pi-acp spawns), credentials
/// (pi's native settings/auth json), and workspace trust — each with its own save,
/// so `AgentDetailView` hides the host "Save" and this view owns the three cards.
struct PiConfigSection: View {
    let model: AgentsSettingsModel
    let agent: AcpAgentInfo
    let client: CodegClient?

    // Runtime
    @State private var mode: PiRuntimeMode
    @State private var command: String
    @State private var configDir: String
    @State private var sessionDir: String
    @State private var showAdvanced = false
    @State private var validation: PiCommandValidation?
    @State private var validating = false
    @State private var piStatus: PiCommandValidation?
    @State private var checkingPi = true
    @State private var piOp: PiOp?
    @State private var savingRuntime = false

    // Credentials (pi's native ~/.pi/agent/{settings,auth,models}.json)
    @State private var selectedProvider = ""
    @State private var customId = ""
    @State private var customBaseUrl = ""
    @State private var customApi = piCustomApiProtocols[0]
    @State private var customProviders: [PiCustomProvider] = []
    @State private var modelText = ""
    @State private var thinkingLevel = ""
    @State private var apiKey = ""
    @State private var authProviders: [String] = []
    @State private var showKey = false
    @State private var savingCreds = false
    @State private var loadingCreds = true

    // Workspace trust
    @State private var trustWorkspace: Bool
    @State private var savingTrust = false

    @State private var banner: Banner?

    enum PiOp: Equatable { case install, uninstall }
    struct Banner: Equatable { let text: String; let isError: Bool }

    init(model: AgentsSettingsModel, agent: AcpAgentInfo, client: CodegClient?) {
        self.model = model
        self.agent = agent
        self.client = client
        let env = agent.env ?? [:]
        let cmd = env[PiEnvKeys.command] ?? ""
        _mode = State(initialValue: cmd.trimmingCharacters(in: .whitespaces).isEmpty ? .default : .custom)
        _command = State(initialValue: cmd)
        _configDir = State(initialValue: env[PiEnvKeys.configDir] ?? "")
        _sessionDir = State(initialValue: env[PiEnvKeys.sessionDir] ?? "")
        _trustWorkspace = State(initialValue: (env[PiEnvKeys.trustWorkspace] ?? "1") != "0")
    }

    // MARK: Derived

    private var isCustomProvider: Bool { selectedProvider == piCustomProviderSentinel }
    private var effectiveProvider: String {
        (isCustomProvider ? customId : selectedProvider).trimmingCharacters(in: .whitespaces)
    }
    private var providerHasKey: Bool { !effectiveProvider.isEmpty && authProviders.contains(effectiveProvider) }
    private var customIncomplete: Bool { mode == .custom && command.trimmingCharacters(in: .whitespaces).isEmpty }
    private var credsIncomplete: Bool {
        effectiveProvider.isEmpty || modelText.trimmingCharacters(in: .whitespaces).isEmpty
            || (isCustomProvider && customBaseUrl.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    /// Built-ins, plus a loaded provider not in the curated list (so a pre-existing
    /// defaultProvider is never dropped from the dropdown).
    private var providerOptions: [(id: String, label: String)] {
        if !selectedProvider.isEmpty, selectedProvider != piCustomProviderSentinel,
           !piBuiltinProviders.contains(where: { $0.id == selectedProvider }) {
            return piBuiltinProviders + [(selectedProvider, selectedProvider)]
        }
        return piBuiltinProviders
    }
    private var divider: some View { Divider().overlay(Theme.hairline) }

    // MARK: Body

    var body: some View {
        VStack(spacing: 16) {
            runtimeCard
            credentialsCard
            trustCard
            if let banner { resultBanner(banner) }
        }
        .task { await loadCreds() }
        .task { await detectPiBinary() }
        .task(id: banner) {
            guard banner != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { banner = nil }
        }
    }

    // MARK: Runtime card

    private var runtimeCard: some View {
        EditorSection(title: "Runtime",
                      footer: "Choose which pi binary runs. Use the default, or point at your own pi build.") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $mode) {
                    Text("Default pi").tag(PiRuntimeMode.default)
                    Text("Custom pi").tag(PiRuntimeMode.custom)
                }
                .pickerStyle(.segmented)
                Text(mode == .default
                     ? "Use the bundled pi-acp adapter with the pi on your PATH. Install pi with: npm install -g @earendil-works/pi-coding-agent"
                     : "Run your own pi build, install, or wrapper.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)

            divider
            if mode == .default { defaultPiRow } else { customCommandRows }
            divider
            HStack(spacing: 10) {
                if customIncomplete {
                    Text("Enter a pi command to save").font(.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                actionButton("Save Runtime", icon: "square.and.arrow.down", busy: savingRuntime,
                             disabled: savingRuntime || customIncomplete, prominent: true, action: handleSaveRuntime)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    /// Default mode → status of the global `pi`, with a single contextual action:
    /// Install when missing, Uninstall when present.
    private var defaultPiRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if checkingPi {
                    Label("Checking…", systemImage: "hourglass").font(.subheadline).foregroundStyle(Theme.textSecondary)
                } else if piStatus?.found == true {
                    Label {
                        Text(piStatus?.version.map { "Installed · \($0)" } ?? "Installed").foregroundStyle(Theme.textPrimary)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    }
                    .font(.subheadline)
                    if let path = piStatus?.resolvedPath, !path.isEmpty {
                        Text(path).font(.caption.monospaced()).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    Label("Not installed", systemImage: "xmark.circle").font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            Button { Task { await detectPiBinary() } } label: {
                Image(systemName: "arrow.clockwise").font(.body.weight(.medium))
            }
            .codegGlassButtonStyle().tint(Theme.textSecondary)
            .disabled(checkingPi || piOp != nil)
            .accessibilityLabel("Recheck")
            if !checkingPi {
                if piStatus?.found == true {
                    actionButton("Uninstall", icon: "trash", busy: piOp == .uninstall,
                                 disabled: piOp != nil, prominent: false, action: handleUninstallPi)
                } else {
                    actionButton("Install pi", icon: "arrow.down.circle", busy: piOp == .install,
                                 disabled: piOp != nil, prominent: true, action: handleInstallPi)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    @ViewBuilder private var customCommandRows: some View {
        FieldRow(label: "pi command or path") {
            HStack(spacing: 8) {
                TextField("/path/to/pi · pi · ./pi-test.sh", text: Binding(
                    get: { command }, set: { command = $0; validation = nil })).agentField()
                Button { Task { await handleValidate() } } label: {
                    if validating { ProgressView().controlSize(.small) }
                    else { Label("Validate", systemImage: "terminal").labelStyle(.titleAndIcon) }
                }
                .font(.subheadline.weight(.medium)).codegGlassButtonStyle().tint(Theme.accent)
                .disabled(validating || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        if let v = validation {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: v.found ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(v.found ? Theme.accent : Theme.danger)
                Text(v.found
                     ? LocalizedStringKey(stringLiteral: [v.resolvedPath, v.version.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
                     : "Command not found")
                    .font(.caption).foregroundStyle(v.found ? Theme.textSecondary : Theme.danger)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
        caption("An absolute path, a command name on PATH, or a wrapper script (e.g. a monorepo ./pi-test.sh).")
        advancedDirs
    }

    private var advancedDirs: some View {
        disclosure("Advanced", isOpen: $showAdvanced) {
            FieldRow(label: "Config directory (PI_CODING_AGENT_DIR)") {
                TextField("~/.pi/agent", text: $configDir).agentField()
            }
            if !configDir.trimmingCharacters(in: .whitespaces).isEmpty {
                caption("With a custom config directory, the Skills, Experts, and Office tools managed in Settings won’t apply to this pi — manage its skills in that folder directly.", tint: Theme.warning)
            }
            FieldRow(label: "Sessions directory (PI_CODING_AGENT_SESSION_DIR)") {
                TextField("~/.pi/agent/sessions", text: $sessionDir).agentField()
            }
            caption("Custom pi flags (--approve, -e, …) aren’t forwarded by pi-acp — wrap pi in a script and point the command at it.")
        }
    }

    // MARK: Credentials card

    private var credentialsCard: some View {
        EditorSection(title: "Pi Configuration",
                      footer: "Pi authenticates with your model provider’s API key. The key is written to ~/.pi/agent/auth.json and the model selection to settings.json.") {
            FieldRow(label: "Provider") {
                SelectField(selection: Binding(get: { selectedProvider }, set: handleProviderChange),
                            options: [SelectOption(value: piCustomProviderSentinel, label: "Custom provider…")]
                                + providerOptions.map { SelectOption(value: $0.id, label: $0.label) },
                            placeholder: "Select a provider")
            }
            if isCustomProvider { customProviderRows }
            divider
            FieldRow(label: "Model") {
                TextField("claude-sonnet-4-20250514", text: $modelText).agentField()
            }
            divider
            FieldRow(label: "Thinking") {
                SelectField(selection: Binding(get: { thinkingLevel.isEmpty ? "off" : thinkingLevel },
                                               set: { thinkingLevel = $0 }),
                            options: piThinkingLevels.map { SelectOption(value: $0, label: piThinkingLabel($0)) })
            }
            divider
            FieldRow(label: "API Key") {
                SecretField(placeholder: providerHasKey ? "•••••• (saved — leave blank to keep)" : "sk-…", text: $apiKey)
            }
            caption("Stored in ~/.pi/agent/auth.json for the selected provider.")
            divider
            HStack {
                Spacer(minLength: 0)
                actionButton("Save Pi Config", icon: "square.and.arrow.down", busy: savingCreds,
                             disabled: savingCreds || loadingCreds || credsIncomplete, prominent: true, action: handleSaveCreds)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    @ViewBuilder private var customProviderRows: some View {
        divider
        FieldRow(label: "Provider ID") { TextField("my-provider", text: $customId).agentField() }
        FieldRow(label: "API protocol") {
            SelectField(selection: $customApi, options: piCustomApiProtocols.map { SelectOption(value: $0, label: $0) })
        }
        FieldRow(label: "API endpoint (Base URL)") {
            TextField("https://api.example.com/v1", text: $customBaseUrl).agentField().keyboardType(.URL)
        }
        caption("Defines a provider in ~/.pi/agent/models.json at your endpoint. Most self-hosted or proxy servers use openai-completions.")
    }

    // MARK: Trust card

    private var trustCard: some View {
        EditorSection(title: "Auto-trust opened workspaces") {
            Toggle(isOn: Binding(get: { trustWorkspace }, set: { toggleTrust($0) })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto-trust opened workspaces").font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Text("When codeg connects pi to a folder, mark that folder trusted so pi loads the project’s local config and skills without a separate prompt.")
                        .font(.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.accent)
            .disabled(savingTrust)
            .padding(.horizontal, 16).padding(.vertical, 13)
            caption("Only folders you open here are trusted, never your whole machine — and this affects config loading only, not what pi is allowed to run.")
        }
    }

    // MARK: Banner + shared rows

    private func resultBanner(_ b: Banner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: b.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(b.isError ? Theme.danger : Theme.accent)
            Text(LocalizedStringKey(stringLiteral: b.text)).font(.caption)
                .foregroundStyle(b.isError ? Theme.danger : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    @ViewBuilder
    private func actionButton(_ title: LocalizedStringKey, icon: String, busy: Bool,
                              disabled: Bool, prominent: Bool, action: @escaping () -> Void) -> some View {
        let label = Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) } else { Image(systemName: icon) }
                Text(title).fontWeight(.semibold)
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
        }
        if prominent {
            label.codegGlassButtonStyle(prominent: true).tint(Theme.accent).disabled(disabled)
        } else {
            label.codegGlassButtonStyle().tint(Theme.accent).disabled(disabled)
        }
    }

    @ViewBuilder
    private func disclosure<C: View>(_ title: LocalizedStringKey, isOpen: Binding<Bool>, @ViewBuilder content: () -> C) -> some View {
        Button { withAnimation(.snappy(duration: 0.2)) { isOpen.wrappedValue.toggle() } } label: {
            HStack(spacing: 8) {
                Text(title).font(.subheadline).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
        .buttonStyle(.plain)
        if isOpen.wrappedValue { content() }
    }

    private func caption(_ text: LocalizedStringKey, tint: Color = Theme.textTertiary) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func piThinkingLabel(_ level: String) -> String {
        switch level {
        case "off": return "Off"
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra high"
        default: return level
        }
    }

    // MARK: Actions

    private func loadCreds() async {
        loadingCreds = true
        defer { loadingCreds = false }
        guard let cfg = try? await client?.loadPiConfig() else { return }
        modelText = cfg.defaultModel ?? ""
        thinkingLevel = cfg.defaultThinkingLevel ?? ""
        authProviders = cfg.authProviders
        customProviders = cfg.customProviders
        let dp = cfg.defaultProvider ?? ""
        if let matched = cfg.customProviders.first(where: { $0.id == dp }) {
            selectedProvider = piCustomProviderSentinel
            customId = matched.id
            customBaseUrl = matched.baseUrl
            customApi = matched.api.isEmpty ? piCustomApiProtocols[0] : matched.api
        } else {
            selectedProvider = dp
        }
    }

    private func detectPiBinary() async {
        checkingPi = true
        defer { checkingPi = false }
        piStatus = (try? await client?.validatePiCommand("pi")) ?? PiCommandValidation(found: false, resolvedPath: nil, version: nil)
    }

    private func handleValidate() async {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        validating = true
        validation = nil
        defer { validating = false }
        validation = (try? await client?.validatePiCommand(cmd)) ?? PiCommandValidation(found: false, resolvedPath: nil, version: nil)
    }

    private func handleProviderChange(_ value: String) {
        selectedProvider = value
        // Switching to custom with nothing typed → prefill from an existing custom provider.
        if value == piCustomProviderSentinel, customId.trimmingCharacters(in: .whitespaces).isEmpty,
           let first = customProviders.first {
            customId = first.id
            customBaseUrl = first.baseUrl
            customApi = first.api.isEmpty ? piCustomApiProtocols[0] : first.api
        }
    }

    private func handleSaveRuntime() {
        let env = PiConfig.buildRuntimeEnv(agent.env ?? [:], mode: mode, command: command,
                                           configDir: configDir, sessionDir: sessionDir)
        savingRuntime = true
        Task {
            do {
                try await model.update(agent, enabled: agent.enabled, env: env, modelProviderId: agent.modelProviderId)
                banner = Banner(text: "Pi runtime saved", isError: false)
            } catch { banner = Banner(text: error.localizedDescription, isError: true) }
            savingRuntime = false
        }
    }

    private func handleSaveCreds() {
        let trimmedModel = modelText.trimmingCharacters(in: .whitespaces)
        guard !effectiveProvider.isEmpty, !trimmedModel.isEmpty else {
            banner = Banner(text: "Provider and model are required", isError: true); return
        }
        let trimmedBase = customBaseUrl.trimmingCharacters(in: .whitespaces)
        if isCustomProvider && trimmedBase.isEmpty {
            banner = Banner(text: "API endpoint (Base URL) is required", isError: true); return
        }
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        let body = UpdatePiConfigBody(
            provider: effectiveProvider, model: trimmedModel,
            thinkingLevel: thinkingLevel.isEmpty ? nil : thinkingLevel,
            apiKey: key.isEmpty ? nil : key,
            customBaseUrl: isCustomProvider ? trimmedBase : nil,
            customApi: isCustomProvider ? customApi : nil)
        savingCreds = true
        Task {
            do {
                try await client?.updatePiConfig(body)
                if !key.isEmpty {
                    apiKey = ""
                    if !authProviders.contains(effectiveProvider) { authProviders = (authProviders + [effectiveProvider]).sorted() }
                }
                if isCustomProvider {
                    customProviders.removeAll { $0.id == effectiveProvider }
                    customProviders.append(PiCustomProvider(id: effectiveProvider, baseUrl: trimmedBase, api: customApi))
                    customProviders.sort { $0.id < $1.id }
                }
                banner = Banner(text: "Pi config saved", isError: false)
            } catch { banner = Banner(text: error.localizedDescription, isError: true) }
            savingCreds = false
        }
    }

    private func handleInstallPi() {
        piOp = .install
        Task {
            do {
                try await client?.installPiBinary(taskId: UUID().uuidString)
                banner = Banner(text: "pi installed", isError: false)
            } catch { banner = Banner(text: "Failed to install pi", isError: true) }
            piOp = nil
            await detectPiBinary()
        }
    }

    private func handleUninstallPi() {
        piOp = .uninstall
        Task {
            do {
                try await client?.uninstallPiBinary(taskId: UUID().uuidString)
                banner = Banner(text: "pi uninstalled", isError: false)
            } catch { banner = Banner(text: "Failed to uninstall pi", isError: true) }
            piOp = nil
            await detectPiBinary()
        }
    }

    /// Self-persisting toggle: default on ⇒ omit the key when enabling (absence =
    /// default), write "0" when disabling. Reverts on failure.
    private func toggleTrust(_ next: Bool) {
        trustWorkspace = next
        var env = agent.env ?? [:]
        if next { env.removeValue(forKey: PiEnvKeys.trustWorkspace) } else { env[PiEnvKeys.trustWorkspace] = "0" }
        savingTrust = true
        Task {
            do {
                try await model.update(agent, enabled: agent.enabled, env: env, modelProviderId: agent.modelProviderId)
            } catch {
                trustWorkspace = !next
                banner = Banner(text: "Failed to save workspace trust", isError: true)
            }
            savingTrust = false
        }
    }
}
