import SwiftUI

// Per-agent-type structured config forms. Each binds to the shared `AgentDraft`
// and calls `draft.reapply(_:)` after every edit so the raw config/env (and the
// save payload) stay in lockstep. API keys use `SecretField`; in model_provider
// mode the URL/key are read-only reflections of the linked provider (iOS never
// holds the provider's real key — it's masked — so only the link is persisted).

// Shared by the per-agent config sections (incl. the self-contained Kimi / Pi
// views in their own files), so it's internal rather than file-private.
extension View {
    func agentField() -> some View {
        self.font(.mono(13)).textInputAutocapitalization(.never).autocorrectionDisabled(true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReadonlyRow: View {
    let label: LocalizedStringKey
    let value: String
    var body: some View {
        FieldRow(label: label) {
            Text(value.isEmpty ? "—" : value)
                .font(.mono(13)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Claude

struct ClaudeConfigSection: View {
    @Binding var draft: AgentDraft
    /// Already filtered to the claude agent type by the host.
    let providers: [ModelProviderInfo]
    /// The three per-tier default models are advanced/rarely-set, so they live
    /// behind a collapsible row to keep the common case short. Auto-expands on
    /// appear when any tier value is already set (so loaded values stay visible).
    @State private var showTierModels = false

    private func bind(_ kp: WritableKeyPath<AgentDraft, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = $0; draft.reapply(.claudeCode) })
    }
    private var selectedProvider: ModelProviderInfo? { providers.first { $0.id == draft.modelProviderId } }

    var body: some View {
        // Web `generalConfigDescriptionClaude` → section footer (out of the card,
        // so the first thing in the card is an actual control, not gray prose).
        EditorSection(title: "Configuration",
                      footer: "Supports quick configuration for API URL, API Key and Claude models, and syncs with native JSON config.") {
            FieldRow(label: "Auth Mode") {
                SelectField(selection: Binding(get: { draft.claudeAuthMode }, set: setAuth), options: [
                    SelectOption(value: .officialSubscription, label: "Official Subscription"),
                    SelectOption(value: .custom, label: "Custom Endpoint"),
                    SelectOption(value: .modelProvider, label: "Model Provider"),
                ])
            }
            subCaption(authModeHint)  // per-mode explainer, aligned under the picker
            switch draft.claudeAuthMode {
            case .officialSubscription:
                modelFields
            case .custom:
                divider
                FieldRow(label: "API URL") { TextField("https://api.anthropic.com", text: bind(\.apiBaseUrl)).agentField() }
                divider
                FieldRow(label: "API Key") { SecretField(placeholder: "sk-ant-…", text: bind(\.apiKey)) }
                modelFields
            case .modelProvider:
                divider
                providerSection
            }
            divider
            FieldRow(label: "Reasoning Effort Level") {
                SelectField(selection: Binding(get: { draft.claudeEffortLevel },
                                               set: { draft.claudeEffortLevel = $0; draft.reapply(.claudeCode) }), options: [
                    SelectOption(value: .default, label: "Default Level"),
                    SelectOption(value: .low, label: "Low"),
                    SelectOption(value: .medium, label: "Medium"),
                    SelectOption(value: .high, label: "High"),
                    SelectOption(value: .xhigh, label: "Extra High"),
                ])
            }
        }
        // Expand once any tier value exists — also catches `providers` loading
        // async after first appear (provider mode), not just the initial render.
        // Only ever opens (never force-collapses a user's manual toggle).
        .onChange(of: hasTierValues, initial: true) { _, hasValues in
            if hasValues { showTierModels = true }
        }
    }

    // Editable models (official / custom). Main + Reasoning stay visible; the
    // three per-tier defaults collapse behind a disclosure row. Labels mirror
    // web `claude.*Model`.
    @ViewBuilder private var modelFields: some View {
        divider; FieldRow(label: "Main Model") { TextField("claude-sonnet-4-6", text: bind(\.claudeMainModel)).agentField() }
        divider; FieldRow(label: "Reasoning Model (thinking)") { TextField("claude-opus-4-8", text: bind(\.claudeReasoningModel)).agentField() }
        divider; tierDisclosureRow
        if showTierModels {
            divider; FieldRow(label: "Default Haiku Model") { TextField("claude-haiku-4-5-20251001", text: bind(\.claudeDefaultHaikuModel)).agentField() }
            divider; FieldRow(label: "Default Sonnet Model") { TextField("claude-sonnet-4-6", text: bind(\.claudeDefaultSonnetModel)).agentField() }
            divider; FieldRow(label: "Default Opus Model") { TextField("claude-opus-4-8", text: bind(\.claudeDefaultOpusModel)).agentField() }
        }
        subCaption("Leave a field empty to use the system default model.")
    }

    // Model-provider mode: picker (or empty hint), then read-only endpoint/key
    // (key masked — iOS never holds the real one) and the provider's read-only
    // model overrides. The draft itself stays scrubbed; the server resolves
    // url/key/models from `modelProviderId`.
    @ViewBuilder private var providerSection: some View {
        if providers.isEmpty {
            hint("No model provider configured for this agent. Add one in Model Provider settings.")
        } else {
            FieldRow(label: "Model Provider") { providerPicker }
            if let p = selectedProvider {
                let pm = ClaudeProviderModel.parse(p.model)
                divider; ReadonlyRow(label: "API URL", value: p.apiUrl)
                divider; ReadonlyRow(label: "API Key", value: p.apiKeyMasked)
                divider; ReadonlyRow(label: "Main Model", value: pm.main)
                divider; ReadonlyRow(label: "Reasoning Model (thinking)", value: pm.reasoning)
                divider; tierDisclosureRow
                if showTierModels {
                    divider; ReadonlyRow(label: "Default Haiku Model", value: pm.haiku)
                    divider; ReadonlyRow(label: "Default Sonnet Model", value: pm.sonnet)
                    divider; ReadonlyRow(label: "Default Opus Model", value: pm.opus)
                }
            }
        }
    }

    // Collapsible header row for the three per-tier default models.
    private var tierDisclosureRow: some View {
        Button { withAnimation(.snappy(duration: 0.2)) { showTierModels.toggle() } } label: {
            HStack(spacing: 8) {
                Text("Default Models by Tier").foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(showTierModels ? 90 : 0))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }

    private var providerPicker: some View {
        SelectField(selection: Binding(get: { draft.modelProviderId },
                                       set: { draft.modelProviderId = $0; draft.reapply(.claudeCode) }),
                    options: [SelectOption(value: Int?.none, label: "Select…")]
                        + providers.map { SelectOption(value: Optional($0.id), label: $0.name) })
    }

    private var divider: some View { Divider().overlay(Theme.hairline) }

    private var authModeHint: LocalizedStringKey {
        switch draft.claudeAuthMode {
        case .officialSubscription: return "Use official Anthropic subscription, no API Key required."
        case .custom: return "Manually configure API URL and API Key for a custom endpoint."
        case .modelProvider: return "Use API URL, API Key, and model from a configured model provider."
        }
    }

    /// True when any per-tier default model already holds a value (editable draft
    /// or the linked provider's parsed model JSON), so the disclosure opens to it.
    private var hasTierValues: Bool {
        if draft.claudeAuthMode == .modelProvider {
            guard let p = selectedProvider else { return false }
            let pm = ClaudeProviderModel.parse(p.model)
            return !(pm.haiku.isEmpty && pm.sonnet.isEmpty && pm.opus.isEmpty)
        }
        return !(draft.claudeDefaultHaikuModel.isEmpty
                 && draft.claudeDefaultSonnetModel.isEmpty
                 && draft.claudeDefaultOpusModel.isEmpty)
    }

    /// Tight tertiary caption that sits inside a row (less padding than `hint`).
    private func subCaption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func setAuth(_ mode: ClaudeAuthMode) {
        draft.claudeAuthMode = mode
        switch mode {
        case .officialSubscription: draft.apiBaseUrl = ""; draft.apiKey = ""; draft.modelProviderId = nil
        case .custom: draft.modelProviderId = nil
        // Auto-select the first available provider (web auto-selects via effect) so
        // the user isn't left on an empty picker with a blocked save.
        case .modelProvider: if draft.modelProviderId == nil, let first = providers.first { draft.modelProviderId = first.id }
        }
        draft.reapply(.claudeCode)
        // Switching to the official subscription must clear EVERY url/key alias from
        // both env + config.env (reapply only clears the canonical pair) so a stale
        // alias can't flip the mode back to "custom" on reload.
        if mode == .officialSubscription {
            let cleared = AgentConfig.clearClaudeCredentialAliases(configText: draft.configText, envText: draft.envText)
            draft.configText = cleared.config
            draft.envText = cleared.env
        }
    }
}

// MARK: - Codex

struct CodexConfigSection: View {
    @Binding var draft: AgentDraft
    let providers: [ModelProviderInfo]

    private func bind(_ kp: WritableKeyPath<AgentDraft, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = $0; draft.reapply(.codex) })
    }
    private func boolBind(_ kp: WritableKeyPath<AgentDraft, Bool>) -> Binding<Bool> {
        Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = $0; draft.reapply(.codex) })
    }
    private var selectedProvider: ModelProviderInfo? { providers.first { $0.id == draft.modelProviderId } }
    private var divider: some View { Divider().overlay(Theme.hairline) }

    var body: some View {
        EditorSection(title: "Configuration") {
            if draft.codexAuthMode == .chatgptSubscription {
                chatgptInfo
            } else {
                FieldRow(label: "Auth Mode") {
                    SelectField(selection: Binding(get: { draft.codexAuthMode }, set: setAuth), options: [
                        SelectOption(value: .apiKey, label: "Custom Endpoint"),
                        SelectOption(value: .modelProvider, label: "Model Provider"),
                    ])
                }
                switch draft.codexAuthMode {
                case .apiKey:
                    divider; FieldRow(label: "API URL") { TextField("https://api.openai.com/v1", text: bind(\.apiBaseUrl)).agentField() }
                    divider; FieldRow(label: "API Key") { SecretField(placeholder: "sk-…", text: bind(\.apiKey)) }
                    divider; FieldRow(label: "Model") { TextField("gpt-5 / gpt-5-mini", text: bind(\.model)).agentField() }
                case .modelProvider:
                    divider; FieldRow(label: "Provider") { providerPicker }
                    if let p = selectedProvider {
                        divider; ReadonlyRow(label: "Endpoint", value: p.apiUrl)
                        divider; ReadonlyRow(label: "Key", value: p.apiKeyMasked)
                    }
                case .chatgptSubscription: EmptyView()
                }
            }
            divider
            FieldRow(label: "Reasoning Effort") {
                SelectField(selection: Binding(get: { draft.codexReasoningEffort },
                                               set: { draft.codexReasoningEffort = $0; draft.reapply(.codex) }),
                            options: codexReasoningEffortOptions.map { SelectOption(value: $0.value, label: $0.label) })
            }
            divider; Toggle("Enable Websocket", isOn: boolBind(\.codexSupportsWebsockets)).tint(Theme.accent).foregroundStyle(Theme.textPrimary).padding(.horizontal, 16).padding(.vertical, 11)
            divider; Toggle("Enable Skills", isOn: boolBind(\.codexSkills)).tint(Theme.accent).foregroundStyle(Theme.textPrimary).padding(.horizontal, 16).padding(.vertical, 11)
            divider; Toggle("Enable Fast", isOn: boolBind(\.codexServiceTierFast)).tint(Theme.accent).foregroundStyle(Theme.textPrimary).padding(.horizontal, 16).padding(.vertical, 11)
        }
    }

    private var chatgptInfo: some View {
        FieldRow(label: "Auth Mode") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Signed in via ChatGPT subscription").foregroundStyle(Theme.textPrimary)
                Text("Manage sign-in on the desktop app. Switch to a custom API key below if you prefer.")
                    .font(.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                Button("Switch to API key") { setAuth(.apiKey) }
                    .font(.subheadline).buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var providerPicker: some View {
        SelectField(selection: Binding(get: { draft.modelProviderId },
                                       set: { draft.modelProviderId = $0; draft.reapply(.codex) }),
                    options: [SelectOption(value: Int?.none, label: "Select…")]
                        + providers.map { SelectOption(value: Optional($0.id), label: $0.name) })
    }

    private func setAuth(_ mode: CodexAuthMode) {
        draft.codexAuthMode = mode
        if mode != .modelProvider { draft.modelProviderId = nil }
        if mode == .modelProvider { draft.apiBaseUrl = ""; draft.apiKey = "" }
        draft.reapply(.codex)
    }
}

// MARK: - Gemini

struct GeminiConfigSection: View {
    @Binding var draft: AgentDraft
    let providers: [ModelProviderInfo]

    private func bind(_ kp: WritableKeyPath<AgentDraft, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = $0; draft.reapply(.gemini) })
    }
    private var selectedProvider: ModelProviderInfo? { providers.first { $0.id == draft.modelProviderId } }
    private var divider: some View { Divider().overlay(Theme.hairline) }
    private var mode: GeminiAuthMode { draft.geminiAuthMode }

    var body: some View {
        EditorSection(title: "Auth Config") {
            FieldRow(label: "Auth Mode") {
                SelectField(selection: Binding(get: { draft.geminiAuthMode }, set: setAuth), options: [
                    SelectOption(value: .custom, label: "Custom Endpoint"),
                    SelectOption(value: .loginGoogle, label: "Google Login (OAuth)"),
                    SelectOption(value: .geminiApiKey, label: "Gemini API Key"),
                    SelectOption(value: .vertexAdc, label: "Vertex AI (ADC)"),
                    SelectOption(value: .vertexServiceAccount, label: "Vertex AI (Service Account)"),
                    SelectOption(value: .vertexApiKey, label: "Vertex AI API Key"),
                    SelectOption(value: .modelProvider, label: "Model Provider"),
                ])
            }
            if mode == .modelProvider {
                divider; FieldRow(label: "Provider") { providerPicker }
                if let p = selectedProvider {
                    divider; ReadonlyRow(label: "Endpoint", value: p.apiUrl)
                    divider; ReadonlyRow(label: "Key", value: p.apiKeyMasked)
                }
            } else {
                if mode == .loginGoogle {
                    divider
                    FieldRow(label: "Sign-in") {
                        Text("Run `gemini` once on the server to complete Google OAuth.")
                            .font(.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if mode == .custom {
                    divider; FieldRow(label: "GOOGLE_GEMINI_BASE_URL") { TextField("https://…", text: bind(\.apiBaseUrl)).agentField() }
                }
                if mode == .custom || mode == .geminiApiKey {
                    divider; FieldRow(label: "GEMINI_API_KEY") { SecretField(placeholder: "AIza…", text: bind(\.geminiApiKey)) }
                }
                if mode == .vertexApiKey {
                    divider; FieldRow(label: "GOOGLE_API_KEY") { SecretField(placeholder: "AIza…", text: bind(\.googleApiKey)) }
                }
                if mode == .vertexAdc || mode == .vertexServiceAccount || mode == .vertexApiKey {
                    divider; FieldRow(label: "GOOGLE_CLOUD_PROJECT") { TextField("my-project", text: bind(\.googleCloudProject)).agentField() }
                    divider; FieldRow(label: "GOOGLE_CLOUD_LOCATION") { TextField("us-central1", text: bind(\.googleCloudLocation)).agentField() }
                }
                if mode == .vertexServiceAccount {
                    divider; FieldRow(label: "GOOGLE_APPLICATION_CREDENTIALS") { TextField("/path/to/key.json", text: bind(\.googleApplicationCredentials)).agentField() }
                }
            }
            divider
            if mode == .modelProvider {
                ReadonlyRow(label: "Model", value: draft.model)
            } else {
                FieldRow(label: "Model") { TextField("gemini-3-pro-preview", text: bind(\.model)).agentField() }
            }
        }
    }

    private var providerPicker: some View {
        SelectField(selection: Binding(get: { draft.modelProviderId },
                                       set: { draft.modelProviderId = $0; draft.reapply(.gemini) }),
                    options: [SelectOption(value: Int?.none, label: "Select…")]
                        + providers.map { SelectOption(value: Optional($0.id), label: $0.name) })
    }

    private func setAuth(_ next: GeminiAuthMode) {
        draft.geminiAuthMode = next
        // Clear fields irrelevant to the target mode (mirror patchGeminiAuthMode).
        var b = "", k = "", g = "", proj = "", loc = "", cred = ""
        func keep() { b = draft.apiBaseUrl; k = draft.geminiApiKey; g = draft.googleApiKey
                      proj = draft.googleCloudProject; loc = draft.googleCloudLocation; cred = draft.googleApplicationCredentials }
        keep()
        switch next {
        case .loginGoogle: b = ""; k = ""; g = ""; proj = ""; loc = ""; cred = ""
        case .custom: g = ""; proj = ""; loc = ""; cred = ""
        case .geminiApiKey: b = ""; g = ""; proj = ""; loc = ""; cred = ""
        case .vertexApiKey: b = ""; k = ""; cred = ""
        case .vertexServiceAccount: b = ""; k = ""; g = ""
        case .vertexAdc: b = ""; k = ""; g = ""; cred = ""
        case .modelProvider: proj = ""; loc = ""; cred = ""
        }
        draft.apiBaseUrl = b; draft.geminiApiKey = k; draft.googleApiKey = g
        draft.googleCloudProject = proj; draft.googleCloudLocation = loc; draft.googleApplicationCredentials = cred
        if next != .modelProvider { draft.modelProviderId = nil }
        draft.reapply(.gemini)
    }
}

// MARK: - OpenClaw

struct OpenClawConfigSection: View {
    @Binding var draft: AgentDraft
    private func bind(_ kp: WritableKeyPath<AgentDraft, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = $0; draft.reapply(.openClaw) })
    }
    private var divider: some View { Divider().overlay(Theme.hairline) }

    var body: some View {
        EditorSection(title: "Gateway Config") {
            FieldRow(label: "Gateway URL") { TextField("wss://gateway-host:18789", text: bind(\.openClawGatewayUrl)).agentField() }
            divider; FieldRow(label: "Gateway Token") { SecretField(placeholder: "token", text: bind(\.openClawGatewayToken)) }
            divider; FieldRow(label: "Session Key") { TextField("agent:main:main", text: bind(\.openClawSessionKey)).agentField() }
        }
    }
}

// MARK: - Cline

struct ClineConfigSection: View {
    @Binding var draft: AgentDraft
    private func bind(_ kp: WritableKeyPath<AgentDraft, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = $0; draft.reapply(.cline) })
    }
    private var divider: some View { Divider().overlay(Theme.hairline) }

    var body: some View {
        EditorSection(title: "Cline") {
            FieldRow(label: "Provider") {
                SelectField(selection: Binding(get: { draft.clineProvider },
                                               set: { draft.clineProvider = $0; draft.reapply(.cline) }),
                            options: clineProviders.map { SelectOption(value: $0.value, label: $0.label) })
            }
            divider; FieldRow(label: "API Key") { SecretField(placeholder: "sk-…", text: bind(\.clineApiKey)) }
            divider; FieldRow(label: "Model") { TextField("claude-sonnet-4-5-20250514", text: bind(\.clineModel)).agentField() }
            divider; FieldRow(label: "API URL") { TextField("https://api.openai.com", text: bind(\.clineBaseUrl)).agentField() }
        }
    }
}

// MARK: - CodeBuddy

/// CodeBuddy authenticates purely through env vars, so this binds the shared draft
/// (like OpenClaw) — the host's "Save" writes them via `acp_update_agent_env`. The
/// environment picker drives `CODEBUDDY_INTERNET_ENVIRONMENT`; "Self-hosted" swaps
/// the region hint for a validated `CODEBUDDY_BASE_URL` field.
struct CodeBuddyConfigSection: View {
    @Binding var draft: AgentDraft

    private func bind(_ kp: WritableKeyPath<AgentDraft, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = $0; draft.reapply(.codeBuddy) })
    }
    private var divider: some View { Divider().overlay(Theme.hairline) }
    private var isSelfHosted: Bool { draft.codeBuddyEnvironment == .selfHosted }
    private var baseUrlInvalid: Bool {
        isSelfHosted
            && !draft.codeBuddyBaseUrl.trimmingCharacters(in: .whitespaces).isEmpty
            && !AgentConfig.isValidCodeBuddyBaseUrl(draft.codeBuddyBaseUrl)
    }

    var body: some View {
        EditorSection(title: "CodeBuddy Configuration",
                      footer: "CodeBuddy authenticates with an API key. Mainland China builds also require the environment set to “China (internal)”; iOA builds use “iOA”. The overseas build leaves it unset.") {
            FieldRow(label: "API Key") { SecretField(placeholder: "sk-…", text: bind(\.apiKey)) }
            caption(isSelfHosted
                ? "Saved as CODEBUDDY_API_KEY for this agent. Use the key issued by your private deployment."
                : "Saved as CODEBUDDY_API_KEY for this agent. Alternatively, sign in with the CodeBuddy CLI in a terminal.")
            divider
            FieldRow(label: "Environment") {
                SelectField(selection: Binding(get: { draft.codeBuddyEnvironment },
                                               set: { draft.codeBuddyEnvironment = $0; draft.reapply(.codeBuddy) }),
                            options: [
                    SelectOption(value: .overseas, label: "Overseas (default)"),
                    SelectOption(value: .internal, label: "China (internal)"),
                    SelectOption(value: .ioa, label: "iOA"),
                    SelectOption(value: .selfHosted, label: "Self-hosted (private deployment)"),
                ])
            }
            if isSelfHosted {
                divider
                FieldRow(label: "Deployment URL") {
                    TextField("https://codebuddy.your-company.com", text: bind(\.codeBuddyBaseUrl))
                        .agentField().keyboardType(.URL)
                }
                caption(baseUrlInvalid
                    ? "Enter a valid http(s) URL."
                    : "Saved as CODEBUDDY_BASE_URL and points CodeBuddy at your private endpoint. The region setting is left unset for self-hosted deployments.",
                    isError: baseUrlInvalid)
            } else {
                caption("Sets CODEBUDDY_INTERNET_ENVIRONMENT. Mainland China must use “China (internal)”; the overseas build leaves it unset.")
                caption("No API key? Run “codebuddy” in a terminal to sign in with your Tencent account instead.")
            }
        }
    }

    private func caption(_ text: LocalizedStringKey, isError: Bool = false) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isError ? Theme.danger : Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 12)
    }
}

// MARK: - Grok

/// Grok is a hybrid: XAI_API_KEY rides the env (like CodeBuddy), while the two
/// structured controls — permission mode + reasoning effort — plus the raw
/// config.toml escape hatch (in the host's Advanced editor) are persisted via
/// `acp_update_agent_config` (grok_structured / grok_config_toml). The host's
/// single "Save" writes env then config in one shot, so this only binds the
/// shared draft; `""` is the canonical "use default" for each dropdown.
struct GrokConfigSection: View {
    @Binding var draft: AgentDraft

    /// API key edits re-bake XAI_API_KEY into `envText`; the dropdowns are read
    /// straight from the draft at save time, so they set the value without reapply.
    private func bindKey() -> Binding<String> {
        Binding(get: { draft.apiKey }, set: { draft.apiKey = $0; draft.reapply(.grok) })
    }
    private func bindString(_ kp: WritableKeyPath<AgentDraft, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = $0 })
    }
    private var divider: some View { Divider().overlay(Theme.hairline) }
    private var keyConfigured: Bool { !draft.apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        EditorSection(title: "Grok Configuration",
                      footer: "The controls below merge into ~/.grok/config.toml, preserving your other keys and comments. Other keys stay editable under Advanced.") {
            FieldRow(label: "Permission Mode") {
                SelectField(selection: bindString(\.grokPermissionMode), options: [
                    SelectOption(value: "", label: "Use default"),
                    SelectOption(value: "ask", label: "Ask every time"),
                    SelectOption(value: "always-approve", label: "Always approve"),
                ])
            }
            divider
            FieldRow(label: "Reasoning Effort") {
                SelectField(selection: bindString(\.grokReasoningEffort), options: [
                    SelectOption(value: "", label: "Use default"),
                    SelectOption(value: "low", label: "Low (faster)"),
                    SelectOption(value: "medium", label: "Medium (balanced)"),
                    SelectOption(value: "high", label: "High"),
                    SelectOption(value: "xhigh", label: "Max"),
                ])
            }
            divider
            FieldRow(label: "API Key") { SecretField(placeholder: "xai-…", text: bindKey()) }
            caption(keyConfigured ? "XAI_API_KEY is configured." : "No XAI_API_KEY set.")
            caption("Saved as XAI_API_KEY for this agent, or run “grok login” in a terminal for subscription sign-in (SuperGrok / X Premium+).")
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 12)
    }
}

// OpenCodeConfigSection → AgentConfigOpenCode.swift; HermesConfigSection → AgentConfigHermes.swift.

// MARK: - Custom (user-registered) ACP agent

/// Config form for an agent codeg has no compile-time knowledge of — a
/// user-registered ACP agent (``AgentType/other(wire:)``, codeg ≥0.22.0).
///
/// There is no structured form to show: the agent's launch metadata lives in the
/// server's database rather than in this build, and the server reports no config
/// file for it (`agent_local_config_path` returns `None`), so the host's
/// "Advanced" raw-config editor is hidden for these too. What IS both editable
/// and useful is the environment — an arbitrary ACP agent's credentials and
/// endpoint overrides all arrive that way — so this exposes it directly as the
/// `KEY=VALUE` text the save path already parses (`EnvText.parse`).
struct CustomAgentConfigSection: View {
    let agentType: AgentType
    let agent: AcpAgentInfo
    @Binding var draft: AgentDraft
    let client: CodegClient?

    /// `supports_mcp` from the stored definition, nil until the read lands. The
    /// card stays away until then: a switch drawn before its value is known
    /// would be a claim rather than a reflection. It also stays away when there
    /// is nothing to read — no client, or no stored definition (`customId` is nil
    /// for an unknown *built-in* from a newer server).
    ///
    /// A FAILED read likewise just hides the card, with nothing said. That is a
    /// deliberate floor rather than a good outcome: this endpoint is a second
    /// call on the same server that already answered `acp_list_agents` for the
    /// screen around it, so it failing alone is unlikely, and an error banner for
    /// a declaration the user may not have come here for would be noisier than
    /// the missing card. The declaration itself is untouched either way.
    @State private var supportsMcp: Bool?
    @State private var savingMcp = false
    @State private var mcpError: String?

    /// The stored definition's id — nil for anything that isn't a user-registered
    /// agent. Doubles as the load's `.task` key.
    private var registryId: String? { agentType.customId }

    var body: some View {
        VStack(spacing: 16) {
            // Whether codeg's MCP companion may ride along comes before the
            // environment: with it wrong the agent may not connect at all.
            if let supportsMcp {
                CustomAgentMcpSection(supportsMcp: supportsMcp, saving: savingMcp,
                                      errorMessage: mcpError, set: applyMcp)
            }
            environmentSection
        }
        // On the always-rendered container, not on the card: an `if` that
        // resolves to nothing is an `EmptyView`, which has no lifecycle, so a
        // `.task` hung off it would never run and the value would never load.
        .task(id: registryId) { await loadMcp() }
    }

    private func loadMcp() async {
        guard let client, let registryId,
              let stored = try? await client.customAgentsRaw() else { return }
        supportsMcp = stored
            .first { $0["registryId"] as? String == registryId }?["supportsMcp"] as? Bool
    }

    /// Optimistic: the switch shows the target state while the save runs and
    /// snaps back if it fails.
    private func applyMcp(_ next: Bool) {
        guard let client, let registryId else { return }
        let previous = supportsMcp
        supportsMcp = next
        savingMcp = true
        mcpError = nil
        Task {
            do {
                // Patch only this declaration — the rest of the definition is
                // re-read server-side at write time, so this can't revert a
                // change some other surface made after this screen appeared.
                try await client.patchCustomAgent(registryId: registryId, patch: ["supportsMcp": next])
            } catch {
                // A failed save does NOT prove nothing was written: the server
                // upserts the row and only then re-hydrates its launch registry,
                // and the second half can be what failed. So fall back to the
                // pre-flip value, then re-read and let the server settle it.
                supportsMcp = previous
                mcpError = (error as? APIError)?.errorDescription ?? error.localizedDescription
                await loadMcp()
            }
            savingMcp = false
        }
    }

    private var environmentSection: some View {
        EditorSection(title: "Environment",
                      footer: "One KEY=VALUE per line, passed to the agent process on launch.") {
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $draft.envText)
                    .agentField()
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12).padding(.vertical, 10)

                Divider().overlay(Theme.hairline)

                Text(originNote)
                    .font(.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }

    /// Says where the definition came from, so it's clear this screen edits the
    /// agent's environment and not the definition itself (which is registered
    /// and edited on the desktop app).
    private var originNote: LocalizedStringKey {
        switch agent.customSource {
        case "registry":
            return "Added from the ACP agent registry. Its command and launch settings are managed on the desktop app."
        case "manual":
            return "Added manually. Its command and launch settings are managed on the desktop app."
        default:
            return "This agent isn’t one codeg ships built-in support for, so only its environment is editable here."
        }
    }
}

/// The MCP declaration on a custom agent's stored definition (`supports_mcp`).
///
/// codeg injects its own codeg-mcp companion into `session/new`'s `mcpServers`
/// — that is what backs delegation, live feedback and the task tools. Most ACP
/// agents accept it, but some reject any entry in that field and fail session
/// creation outright, so the agent can't be connected to at all until the
/// injection stops. codeg can't detect which kind an arbitrary agent is, so the
/// user declares it here (OpenClaw is the built-in precedent, where the same
/// flag is a compile-time constant).
///
/// Unlike everything else on this screen, this lives on the DEFINITION rather
/// than the env, so it saves on its own switch rather than through the host's
/// "Save" — see ``CodegClient/patchCustomAgent(registryId:patch:)``. It takes
/// effect on the next connection; a running session keeps the servers it started
/// with.
private struct CustomAgentMcpSection: View {
    let supportsMcp: Bool
    let saving: Bool
    let errorMessage: String?
    let set: (Bool) -> Void

    var body: some View {
        EditorSection(title: "MCP") {
            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: Binding(get: { supportsMcp }, set: set)) {
                    Text("Supports MCP servers")
                }
                .tint(Theme.accent)
                .foregroundStyle(Theme.textPrimary)
                .disabled(saving)
                .padding(.horizontal, 16).padding(.vertical, 11)

                Text("codeg sends its companion MCP server when a session starts. Turn this off for an agent that rejects MCP servers and fails to connect.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 12)

                if let errorMessage {
                    Text(LocalizedStringKey(stringLiteral: errorMessage))
                        .font(.caption).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
        }
    }
}
