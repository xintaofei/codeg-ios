import SwiftUI

/// Self-contained Kimi Code settings panel (ported from the web `KimiCodeConfigPanel`).
/// Kimi has a dedicated backend (`acp_update_kimi_code_config`) and per-section
/// state that doesn't live in the shared config.json/env draft, so — unlike the
/// draft-bound agents — it owns its `@State` (seeded from the projected
/// `agent.configJson`) and its own Save button(s); `AgentDetailView` hides the host
/// "Save" for Kimi. Two authoritative modes plus a raw config.toml escape hatch.
struct KimiConfigSection: View {
    let model: AgentsSettingsModel
    /// Live agent (re-read by the host each render) — its `configJson` drives the
    /// gate-status banner so it reflects the fresh backend state after a save.
    let agent: AcpAgentInfo
    let client: CodegClient?

    @State private var mode: KimiAuthMode
    @State private var interfaceType: KimiInterfaceType
    @State private var region: KimiEndpointRegion
    @State private var baseUrl: String
    @State private var authType: KimiNativeAuthType
    @State private var apiKey: String
    @State private var modelId: String
    @State private var maxContext: String
    @State private var vertexProject: String
    @State private var vertexLocation: String
    @State private var rawConfig: String

    @State private var models: [String] = []
    @State private var showKey = false
    @State private var showAuthType = false
    @State private var showRawEditor = false
    @State private var saving = false
    @State private var fetchingModels = false
    @State private var banner: Banner?

    struct Banner: Equatable { let text: String; let isError: Bool }

    init(model: AgentsSettingsModel, agent: AcpAgentInfo, client: CodegClient?) {
        self.model = model
        self.agent = agent
        self.client = client
        let c = KimiManagedConfig.parse(agent.configJson)
        _mode = State(initialValue: kimiInitialMode(c))
        let itype = c.interfaceType ?? .kimi
        _interfaceType = State(initialValue: itype)
        _region = State(initialValue: kimiEndpointRegionFromBaseUrl(c.baseUrl ?? ""))
        _baseUrl = State(initialValue: c.baseUrl ?? kimiInterfaceMeta(itype).defaultBaseUrl)
        _authType = State(initialValue: c.authType ?? .apiKey)
        _apiKey = State(initialValue: c.key ?? "")
        _modelId = State(initialValue: c.modelId ?? "")
        _maxContext = State(initialValue: c.maxContextSize.map(String.init) ?? "")
        _vertexProject = State(initialValue: c.vertexProject ?? "")
        _vertexLocation = State(initialValue: c.vertexLocation ?? "")
        _rawConfig = State(initialValue: c.rawConfigToml ?? "")
    }

    // MARK: Derived

    private var meta: KimiInterfaceTypeMeta { kimiInterfaceMeta(interfaceType) }
    private var isKimi: Bool { interfaceType == .kimi }
    private var isVertex: Bool { interfaceType == .vertexai }
    private var effectiveBaseUrl: String {
        isKimi ? kimiBaseUrlForRegion(region, baseUrl) : baseUrl.trimmingCharacters(in: .whitespaces)
    }
    private var liveConfig: KimiManagedConfig { KimiManagedConfig.parse(agent.configJson) }
    private var divider: some View { Divider().overlay(Theme.hairline) }

    // MARK: Body

    var body: some View {
        EditorSection(title: "Kimi Code Configuration",
                      footer: "`kimi acp` only authenticates with a stored login token and rejects API keys on their own. To use an API key, codeg writes a managed ~/.kimi-code/config.toml provider AND seeds a local gate token so the session opens — inference still runs on your key.") {
            gateBanner
            if let banner { resultBanner(banner) }
            divider
            FieldRow(label: "Authentication method") {
                SelectField(selection: $mode, options: [
                    SelectOption(value: .apikey, label: "API key"),
                    SelectOption(value: .login, label: "Kimi account login (subscription)"),
                ])
            }
            caption("“API key” writes a codeg-managed config.toml provider and seeds a gate token. “Login” clears that and uses a real `kimi login` session (requires a Kimi subscription).")

            if mode == .apikey { apiKeyForm } else { caption("Run `kimi login` in a terminal to sign in with a Kimi subscription account (device-code OAuth). codeg stores nothing and reuses Kimi’s own login. Saving here removes codeg’s API-key gate token.") }

            divider
            saveRow(title: "Save Kimi Code Config", action: handleSave)
            divider
            rawEditorDisclosure
        }
        .task(id: banner) {
            guard banner != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { banner = nil }
        }
    }

    // MARK: API-key form

    @ViewBuilder private var apiKeyForm: some View {
        divider
        FieldRow(label: "Provider type") {
            SelectField(selection: Binding(get: { interfaceType }, set: setInterface),
                        options: kimiInterfaceTypes.map { SelectOption(value: $0.value, label: $0.label) })
        }
        caption("The provider protocol Kimi speaks (config.toml `type`). Use Kimi / Moonshot for a Moonshot / platform.kimi.com key.")

        if isKimi {
            divider
            FieldRow(label: "Endpoint") {
                SelectField(selection: $region, options: [
                    SelectOption(value: .international, label: "International (api.moonshot.ai)"),
                    SelectOption(value: .china, label: "China (api.moonshot.cn)"),
                    SelectOption(value: .custom, label: "Custom (OpenAI-compatible)"),
                ])
            }
            if region == .custom {
                FieldRow(label: "Base URL") { field($baseUrl, "https://api.example.com/v1", url: true) }
            }
            caption("International = api.moonshot.ai; China (platform.kimi.com keys) = api.moonshot.cn. Custom points at any OpenAI-compatible endpoint.")
        } else {
            divider
            FieldRow(label: "Base URL") { field($baseUrl, "https://api.example.com/v1", url: true) }
            caption("Leave blank to use the provider SDK default.")
        }

        if meta.usesApiKey {
            divider
            FieldRow(label: "API Key") { SecretField(placeholder: "sk-…", text: $apiKey) }
            caption("Written to ~/.kimi-code/config.toml and used for inference. From platform.kimi.com or platform.kimi.ai.")
            authTypeDisclosure
        } else {
            divider
            FieldRow(label: "GCP project (GOOGLE_CLOUD_PROJECT)") { field($vertexProject, "my-gcp-project") }
            FieldRow(label: "GCP location (GOOGLE_CLOUD_LOCATION)") { field($vertexLocation, "us-central1") }
            caption("Vertex AI uses Google Application Default Credentials — run `gcloud auth application-default login` (no API key).")
        }

        divider
        FieldRow(label: "Model") {
            HStack(spacing: 8) {
                field($modelId, kimiModelPlaceholder)
                if !models.isEmpty { modelSuggestionsMenu }
                Button { fetchModels() } label: {
                    if fetchingModels { ProgressView().controlSize(.small) }
                    else { Label("Fetch", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon) }
                }
                .font(.subheadline.weight(.medium))
                .codegGlassButtonStyle().tint(Theme.accent)
                .disabled(saving || fetchingModels)
            }
        }
        caption("The model id to use. Click Fetch to list the models your key can access (e.g. kimi-k2.7-code) — avoids “model not found” errors.")

        divider
        FieldRow(label: "Max context size (optional)") {
            TextField("262144", text: $maxContext).agentField().keyboardType(.numberPad)
        }
        caption("Tokens, e.g. 262144. Leave blank to use the model default.")
    }

    private var modelSuggestionsMenu: some View {
        Menu {
            ForEach(models, id: \.self) { m in
                Button(m) { modelId = m }
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.body.weight(.medium)).frame(width: 34, height: 30)
        }
        .codegGlassButtonStyle().tint(Theme.textSecondary)
        .accessibilityLabel("Choose a fetched model")
    }

    private var authTypeDisclosure: some View {
        disclosure("Advanced: credential placement", isOpen: $showAuthType) {
            FieldRow(label: "Advanced: credential placement") {
                SelectField(selection: $authType, options: [
                    SelectOption(value: .apiKey, label: "Inline api_key"),
                    SelectOption(value: .env, label: "Provider env sub-table"),
                ])
            }
            caption("Where the API key is written inside config.toml.")
        }
    }

    // MARK: Raw editor

    private var rawEditorDisclosure: some View {
        disclosure("Advanced: edit config.toml directly", isOpen: $showRawEditor) {
            TextEditor(text: $rawConfig)
                .font(.mono(12))
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.hairline))
                .autocorrectionDisabled(true).textInputAutocapitalization(.never)
                .padding(.horizontal, 16).padding(.top, 4)
            caption("Written verbatim (comments preserved) and validated as TOML. codeg also seeds the gate token so the session opens.")
            saveRow(title: "Save config.toml", action: handleSaveRaw, prominent: false)
        }
    }

    // MARK: Banners

    private var gateBanner: some View {
        let present = liveConfig.credentialPresent == true
        let text: LocalizedStringKey = present
            ? (mode == .login
                ? "Authenticated via a Kimi account login."
                : "Authenticated via API key (codeg seeded the local gate token).")
            : "Not authenticated yet — save an API key below (or sign in) to open Kimi sessions."
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: present ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(present ? Theme.accent : Theme.warning)
            Text(text).font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func resultBanner(_ b: Banner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: b.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(b.isError ? Theme.danger : Theme.accent)
            Text(LocalizedStringKey(stringLiteral: b.text)).font(.caption)
                .foregroundStyle(b.isError ? Theme.danger : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    // MARK: Shared row builders

    private func field(_ text: Binding<String>, _ placeholder: String, url: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .agentField()
            .keyboardType(url ? .URL : .default)
    }

    @ViewBuilder
    private func saveRow(title: LocalizedStringKey, action: @escaping () -> Void, prominent: Bool = true) -> some View {
        HStack {
            Spacer(minLength: 0)
            if prominent {
                saveButton(title, action).codegGlassButtonStyle(prominent: true).tint(Theme.accent).disabled(saving)
            } else {
                saveButton(title, action).codegGlassButtonStyle().tint(Theme.accent).disabled(saving)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func saveButton(_ title: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if saving { ProgressView().controlSize(.small) }
                else { Image(systemName: "square.and.arrow.down") }
                Text(title).fontWeight(.semibold)
            }
            .padding(.horizontal, 16).padding(.vertical, 5)
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

    private func caption(_ text: LocalizedStringKey, isError: Bool = false) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(isError ? Theme.danger : Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 12)
    }

    // MARK: Actions

    private func setInterface(_ next: KimiInterfaceType) {
        interfaceType = next
        models = []
        if next == .kimi {
            region = .international
            baseUrl = ""
        } else {
            baseUrl = kimiInterfaceMeta(next).defaultBaseUrl
        }
    }

    private func handleSave() {
        let body: UpdateKimiCodeConfigBody
        if mode == .login {
            body = UpdateKimiCodeConfigBody(mode: "login")
        } else {
            if modelId.trimmingCharacters(in: .whitespaces).isEmpty {
                banner = Banner(text: "Enter a model id (Kimi requires one for API-key mode).", isError: true)
                return
            }
            body = UpdateKimiCodeConfigBody(
                mode: "apikey",
                interfaceType: interfaceType.rawValue,
                authType: meta.usesApiKey ? authType.rawValue : nil,
                baseUrl: effectiveBaseUrl,
                apiKey: meta.usesApiKey ? apiKey : nil,
                model: modelId,
                maxContextSize: Int(maxContext.trimmingCharacters(in: .whitespaces)),
                vertexProject: isVertex ? vertexProject : nil,
                vertexLocation: isVertex ? vertexLocation : nil
            )
        }
        runSave(body, success: "Kimi Code config saved")
    }

    private func handleSaveRaw() {
        runSave(UpdateKimiCodeConfigBody(mode: "raw", rawConfigToml: rawConfig), success: "Kimi Code config saved")
    }

    private func runSave(_ body: UpdateKimiCodeConfigBody, success: String) {
        saving = true
        Task {
            do {
                try await model.saveKimiCodeConfig(body)
                banner = Banner(text: success, isError: false)
            } catch {
                banner = Banner(text: error.localizedDescription, isError: true)
            }
            saving = false
        }
    }

    private func fetchModels() {
        let url = effectiveBaseUrl
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !key.isEmpty else {
            banner = Banner(text: "Enter an API key and endpoint first", isError: true)
            return
        }
        fetchingModels = true
        Task {
            do {
                let list = try await client?.fetchKimiModels(baseUrl: url, apiKey: key) ?? []
                models = list
                banner = Banner(text: list.isEmpty ? "Key works, but no models were returned" : "Found \(list.count) models", isError: false)
            } catch {
                banner = Banner(text: "Couldn’t list models — check the key and endpoint", isError: true)
            }
            fetchingModels = false
        }
    }
}
