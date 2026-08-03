import SwiftUI

/// Add / Edit / View a single agent skill (Markdown). On edit the content is
/// fetched on appear; a `readOnly` skill is shown without a Save action. New
/// skills are created at global scope (folder-scoped skills are deferred).
struct SkillEditorSheet: View {
    enum Mode {
        case create
        case edit(AgentSkillItem)
    }

    let mode: Mode
    let agent: AgentType
    let loadContent: (AgentSkillItem) async throws -> String
    let onSave: (_ skillId: String, _ scope: AgentSkillScope, _ content: String, _ layout: AgentSkillLayout?) async throws -> Void

    @State private var skillId: String
    @State private var content: String = ""
    @State private var isLoadingContent: Bool
    @State private var isSaving = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    init(
        mode: Mode,
        agent: AgentType,
        loadContent: @escaping (AgentSkillItem) async throws -> String,
        onSave: @escaping (String, AgentSkillScope, String, AgentSkillLayout?) async throws -> Void
    ) {
        self.mode = mode
        self.agent = agent
        self.loadContent = loadContent
        self.onSave = onSave
        switch mode {
        case .create:
            _skillId = State(initialValue: "")
            _isLoadingContent = State(initialValue: false)
        case .edit(let skill):
            _skillId = State(initialValue: skill.id)
            _isLoadingContent = State(initialValue: true)
        }
    }

    private var existing: AgentSkillItem? {
        if case .edit(let skill) = mode { return skill } else { return nil }
    }
    private var isReadOnly: Bool { existing?.readOnly ?? false }
    private var scope: AgentSkillScope { existing?.scope ?? .global }
    /// Preserve an existing skill's layout; new skills default to `skill_directory`
    /// (the web's default for every current agent).
    private var layout: AgentSkillLayout? { existing?.layout ?? .skillDirectory }

    private var trimmedId: String { skillId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !isReadOnly && !trimmedId.isEmpty
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSaving && !isLoadingContent
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        EditorSection(title: "Skill", footer: scopeFooter) {
                            FieldRow(label: "ID") {
                                if existing != nil {
                                    Text(skillId)
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    TextField("my-skill", text: $skillId)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled(true)
                                }
                            }
                            // Existing skills show their on-disk path (selectable to
                            // copy). New skills have no path yet, so the row is omitted.
                            if let existing {
                                Divider().overlay(Theme.hairline).padding(.leading, 16)
                                FieldRow(label: "Path") {
                                    Text(existing.path)
                                        .font(.mono(12))
                                        .foregroundStyle(Theme.textSecondary)
                                        .textSelection(.enabled)
                                        .lineLimit(3)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        EditorSection(title: isReadOnly ? "Content" : "Content (Markdown)") {
                            if isLoadingContent {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small).tint(Theme.accent)
                                    Text("Loading…").font(.subheadline).foregroundStyle(Theme.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                            } else if isReadOnly {
                                // Built-in skills can't be edited — render the Markdown
                                // (like the web preview) rather than a disabled raw field.
                                Group {
                                    if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("This skill has no content.")
                                            .font(.subheadline)
                                            .foregroundStyle(Theme.textTertiary)
                                    } else {
                                        MarkdownContent(raw: content)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                            } else {
                                TextField("# Skill\n\nInstructions for the agent…", text: $content, axis: .vertical)
                                    .font(.mono(14))
                                    .lineLimit(8...30)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 13)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isReadOnly ? "Close" : "Cancel") { dismiss() }.tint(Theme.textSecondary)
                }
                if !isReadOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .tint(Theme.accent)
                            .disabled(!canSave)
                    }
                }
            }
            .task { await loadIfNeeded() }
        }
        .presentationDragIndicator(.visible)
        .alert("Couldn’t Save Skill", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var navTitle: LocalizedStringKey {
        if existing == nil { return "New Skill" }
        return isReadOnly ? "View Skill" : "Edit Skill"
    }

    private var scopeFooter: LocalizedStringKey {
        // Localize the scope word itself (via Text interpolation) so it doesn't
        // stay English inside a translated sentence; the agent name is verbatim.
        let scopeWord: LocalizedStringKey = scope == .global ? "Global" : "Project"
        return existing != nil
            ? "\(Text(scopeWord)) skill for \(agent.label)."
            : "New global skill for \(agent.label)."
    }

    private func loadIfNeeded() async {
        guard let existing else { return }
        do { content = try await loadContent(existing) }
        catch { saveError = error.localizedDescription }
        isLoadingContent = false
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let snapshotId = trimmedId
        let snapshotContent = content
        Task {
            do {
                try await onSave(snapshotId, scope, snapshotContent, layout)
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}
