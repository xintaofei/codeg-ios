import SwiftUI

/// Add / Edit an MCP server: an id (locked on edit), the raw JSON spec, and the
/// set of agent apps it's enabled for. Save validates the spec is a JSON object,
/// then upserts (spec + apps together).
struct McpServerEditorSheet: View {
    let editing: LocalMcpServer?
    /// The last scan couldn't read every agent's config. Saving means "these
    /// agents and no others", and an agent that holds this server may be
    /// showing unchecked — so no save until the file is fixed and the list
    /// re-read (web `scanDegraded`). The server refuses one too, but would
    /// accept this stale draft once the file is repaired out of band.
    var saveBlocked = false
    let onSave: (_ serverId: String, _ spec: JSONValue, _ apps: [McpAppType]) async throws -> Void

    @State private var serverId: String
    @State private var specText: String
    @State private var selectedApps: Set<McpAppType>
    @State private var isSaving = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    private static let template = """
    {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-everything"]
    }
    """

    init(editing: LocalMcpServer?, saveBlocked: Bool = false,
         onSave: @escaping (String, JSONValue, [McpAppType]) async throws -> Void) {
        self.editing = editing
        self.saveBlocked = saveBlocked
        self.onSave = onSave
        _serverId = State(initialValue: editing?.id ?? "")
        _specText = State(initialValue: editing?.spec.prettyString ?? Self.template)
        _selectedApps = State(initialValue: Set(editing?.apps ?? []))
    }

    private var trimmedId: String { serverId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedSpec: JSONValue? { JSONValue.parse(specText) }
    private var specIsValidObject: Bool { parsedSpec?.isObject ?? false }
    /// What a save sends: the toggles, plus the server's existing apps that
    /// aren't offered as toggles (kept, never stripped).
    private var appsToSave: [McpAppType] {
        McpAppSelection.apps(selected: selectedApps, existing: editing?.apps ?? [])
    }
    private var canSave: Bool { !saveBlocked && !trimmedId.isEmpty && specIsValidObject && !appsToSave.isEmpty && !isSaving }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        if saveBlocked { saveBlockedNotice }
                        EditorSection(title: "Server", footer: editing == nil ? "A unique id for this MCP server." : nil) {
                            FieldRow(label: "ID") {
                                if editing != nil {
                                    Text(serverId)
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    TextField("my-mcp", text: $serverId)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled(true)
                                }
                            }
                        }
                        EditorSection(title: "Spec (JSON)", footer: Self.typeHint) {
                            TextField("{ }", text: $specText, axis: .vertical)
                                .font(.mono(13))
                                .lineLimit(8...28)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 13)
                            if !specText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Divider().overlay(Theme.hairline).padding(.leading, 16)
                                specValidityRow
                            }
                        }
                        EditorSection(title: "Enabled For", footer: appsToSave.isEmpty ? "Select at least one app." : "Which agents this MCP server is available to.") {
                            ForEach(Array(McpAppType.assignable.enumerated()), id: \.element) { index, app in
                                if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 16) }
                                Toggle(isOn: Binding(
                                    get: { selectedApps.contains(app) },
                                    set: { on in if on { selectedApps.insert(app) } else { selectedApps.remove(app) } }
                                )) {
                                    Text(app.displayName).foregroundStyle(Theme.textPrimary)
                                }
                                .tint(Theme.accent)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(editing == nil ? "Add MCP Server" : "Edit MCP Server")
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
        .alert("Couldn’t Save MCP Server", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    /// Persistent guidance on accepted transports (mirrors the web settings).
    private static let typeHint: LocalizedStringKey = "Supported types: stdio, http (alias: streamable-http), and sse. env applies to stdio only; remote servers carry auth via headers."

    private var saveBlockedNotice: some View {
        Label {
            Text("Fix or remove that file and refresh before saving: assignments are computed from the agents this page could read, so saving now could drop this server from one it could not.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(Theme.warning)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    /// Live validity indicator shown beneath the JSON editor once it's non-empty.
    @ViewBuilder
    private var specValidityRow: some View {
        Label(
            specIsValidObject ? "Valid JSON object" : "Spec must be a JSON object",
            systemImage: specIsValidObject ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(specIsValidObject ? Theme.accent : Theme.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func save() {
        guard canSave, let spec = parsedSpec else { return }
        isSaving = true
        let id = trimmedId
        let apps = appsToSave
        Task {
            do {
                try await onSave(id, spec, apps)
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}
