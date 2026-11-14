import SwiftUI

/// Add / Edit a model provider. Mirrors the web add/edit dialogs:
/// - agent picker limited to `AgentType.modelProviderSupported`;
/// - Claude Code shows the five per-model fields (serialized to the `model` JSON
///   string); other agents show a single model field;
/// - API key uses "blank = keep" on edit (only sent when re-entered);
/// - on edit, name/apiUrl/agentType/model are sent only when changed.
struct ModelProviderEditorSheet: View {
    let editing: ModelProviderInfo?
    let onCreate: (_ name: String, _ apiUrl: String, _ apiKey: String, _ agentType: AgentType, _ model: String?) async throws -> Void
    let onUpdate: (UpdateModelProviderBody) async throws -> Void

    @State private var name: String
    @State private var apiUrl: String
    @State private var apiKey: String = ""
    @State private var agentType: AgentType
    @State private var singleModel: String
    @State private var claude: ClaudeProviderModel
    @State private var isSaving = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    init(
        editing: ModelProviderInfo?,
        onCreate: @escaping (String, String, String, AgentType, String?) async throws -> Void,
        onUpdate: @escaping (UpdateModelProviderBody) async throws -> Void
    ) {
        self.editing = editing
        self.onCreate = onCreate
        self.onUpdate = onUpdate
        _name = State(initialValue: editing?.name ?? "")
        _apiUrl = State(initialValue: editing?.apiUrl ?? "")
        let agent = editing?.agentType ?? AgentType.modelProviderSupported.first ?? .claudeCode
        _agentType = State(initialValue: agent)
        if agent == .claudeCode {
            _claude = State(initialValue: ClaudeProviderModel.parse(editing?.model))
            _singleModel = State(initialValue: "")
        } else {
            _claude = State(initialValue: ClaudeProviderModel())
            _singleModel = State(initialValue: editing?.model ?? "")
        }
    }

    private var isEdit: Bool { editing != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedURL: String { apiUrl.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `nil` when no model is set (create form); used directly for create.
    private var modelValue: String? {
        if agentType == .claudeCode { return claude.serialized() }
        let t = singleModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private var canSave: Bool {
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty, !isSaving else { return false }
        // A key is required to create; on edit a blank field keeps the stored one.
        return isEdit || !trimmedKey.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        detailsSection
                        authSection
                        modelSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(isEdit ? "Edit Provider" : "Add Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .tint(Theme.accent)
                        .disabled(!canSave)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .alert("Couldn’t Save Provider", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Sections

    private var detailsSection: some View {
        // The agent type is immutable after creation (dependent agents bind to a
        // provider by id and rely on its agent_type), so the picker is shown only
        // when adding; on edit it's a static row and never sent in the update.
        EditorSection(title: "Provider", footer: isEdit ? "The agent can’t be changed after the provider is created." : nil) {
            FieldRow(label: "Name") {
                TextField("My provider", text: $name)
            }
            Divider().overlay(Theme.hairline)
            FieldRow(label: "Agent") {
                if isEdit {
                    Text(agentType.displayName)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    SelectField(selection: $agentType,
                                options: AgentType.modelProviderSupported.map { SelectOption(value: $0, label: $0.displayName) })
                }
            }
            Divider().overlay(Theme.hairline)
            FieldRow(label: "API URL") {
                TextField("https://api.example.com/v1", text: $apiUrl)
                    .font(.mono(15))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
        }
    }

    private var authSection: some View {
        EditorSection(
            title: "Authentication",
            footer: isEdit ? "Leave blank to keep the stored API key." : "The API key for this provider."
        ) {
            FieldRow(label: "API Key") {
                SecureField(isEdit ? (editing?.apiKeyMasked.isEmpty == false ? "Keep current key" : "API key") : "API key", text: $apiKey)
                    .font(.mono(15))
                    .textContentType(.password)
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        if agentType == .claudeCode {
            EditorSection(title: "Models", footer: "Optional per-role model overrides. Leave blank to use defaults.") {
                claudeField("Main", text: $claude.main, placeholder: "claude-sonnet-4-6")
                Divider().overlay(Theme.hairline)
                claudeField("Reasoning", text: $claude.reasoning, placeholder: "claude-opus-4-8")
                Divider().overlay(Theme.hairline)
                claudeField("Haiku", text: $claude.haiku, placeholder: "claude-haiku-4-5")
                Divider().overlay(Theme.hairline)
                claudeField("Sonnet", text: $claude.sonnet, placeholder: "claude-sonnet-4-6")
                Divider().overlay(Theme.hairline)
                claudeField("Opus", text: $claude.opus, placeholder: "claude-opus-4-8")
            }
        } else {
            EditorSection(title: "Model", footer: "Optional. Leave blank to use the provider default.") {
                FieldRow(label: "Model") {
                    TextField(modelPlaceholder, text: $singleModel)
                        .font(.mono(15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }
        }
    }

    private func claudeField(_ label: LocalizedStringKey, text: Binding<String>, placeholder: String) -> some View {
        FieldRow(label: label) {
            TextField(placeholder, text: text)
                .font(.mono(15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        }
    }

    private var modelPlaceholder: LocalizedStringKey {
        switch agentType {
        case .codex: "gpt-5-codex"
        case .gemini: "gemini-2.5-pro"
        default: "model name"
        }
    }

    // MARK: - Save

    private func save() {
        guard canSave else { return }
        isSaving = true
        Task {
            do {
                if let editing {
                    try await onUpdate(buildUpdateBody(for: editing))
                } else {
                    try await onCreate(trimmedName, trimmedURL, trimmedKey, agentType, modelValue)
                }
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }

    /// Build the partial update: only fields that changed (nil = keep). The model
    /// field sends an empty string to clear when it changed-to-empty (matching the
    /// web), nil to keep. `agentType` is never sent — it's immutable server-side.
    private func buildUpdateBody(for existing: ModelProviderInfo) -> UpdateModelProviderBody {
        var body = UpdateModelProviderBody(id: existing.id)
        body.name = trimmedName != existing.name ? trimmedName : nil
        body.apiUrl = trimmedURL != existing.apiUrl ? trimmedURL : nil
        body.apiKey = trimmedKey.isEmpty ? nil : trimmedKey
        // Detect model changes SEMANTICALLY so a JSON key-order difference (a
        // web-created Claude provider stores keys in a different order than our
        // serializer) can't trigger a spurious update + server config cascade.
        // `agentType` here always equals `existing.agentType` (picker disabled on
        // edit), so the Claude-vs-single branch matches the stored shape.
        let nextModel = modelValue ?? ""
        let prevModel: String
        if agentType == .claudeCode {
            prevModel = ClaudeProviderModel.parse(existing.model).serialized() ?? ""
        } else {
            prevModel = (existing.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        body.model = nextModel != prevModel ? nextModel : nil
        return body
    }
}
