import SwiftUI

/// Manage tags (web `ConversationTagsManager`): the branch tag, the global
/// tags, and one folder's tags at a time. Tap a tag to edit it; Edit, then drag
/// a tag's handle to reorder its scope, as the web drags (a long-press offers
/// Move Up / Move Down too); swipe to delete (always confirmed). Pushed from the
/// tag picker and the tag filter, inside their sheets.
struct TagsManagerView: View {
    @State private var model: TagsManagerModel
    /// The tag being created (in a scope) or edited.
    @State private var form: TagForm?
    @State private var deleting: ConversationTag?

    init(client: CodegClient) {
        _model = State(initialValue: TagsManagerModel(client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .navigationTitle("Manage tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Drag handles only while editing: outside it a long-press is the
            // row's menu, which a drag would fight.
            if canReorder {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton().tint(Theme.accent)
                }
            }
        }
        .task { await model.load() }
        .sheet(item: $form) { form in
            TagFormSheet(form: form, model: model)
        }
        .alert("Delete this tag?", isPresented: deleteBinding, presenting: deleting) { tag in
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                deleting = nil
                Task { await model.delete(tag) }
            }
        } message: { tag in
            Text("“\(tag.name)” will be taken off every conversation that has it. This can't be undone.")
        }
    }

    /// A scope on screen has two tags or more to put in order.
    private var canReorder: Bool {
        if model.scopeTags(nil).count > 1 { return true }
        guard let folderID = model.selectedFolderID else { return false }
        return model.scopeTags(folderID).count > 1
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading, model.tags.isEmpty, model.loadError == nil {
            LoadingView()
        } else if let error = model.loadError, model.tags.isEmpty {
            InlineErrorView(message: error) {
                Task { await model.load() }
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                Text("Label conversations with colored tags, then filter the list by them.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Color.clear)
                if let error = model.error, form == nil {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .listRowBackground(Color.clear)
                }
            }

            if let branch = model.branchTag {
                branchSection(branch)
            }

            Section {
                tagRows(scope: nil)
                addButton(scope: nil)
            } header: {
                Text("Global tags")
            } footer: {
                Text("Available on every conversation, chat mode included.")
            }

            Section {
                if model.folders.isEmpty {
                    Text("No folders yet. Open one to give it its own tags.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Picker(selection: $model.selectedFolderID) {
                        ForEach(model.folders) { folder in
                            Text(verbatim: folder.name).tag(Optional(folder.id))
                        }
                    } label: {
                        Text("Folder")
                    }
                    .pickerStyle(.menu)
                    if let folderID = model.selectedFolderID {
                        tagRows(scope: folderID)
                        addButton(scope: folderID)
                    }
                }
            } header: {
                Text("Folder tags")
            } footer: {
                Text("Available only on the chosen folder's conversations, its worktrees included.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .disabled(model.isSaving && form == nil)
    }

    // MARK: - Branch tag

    private func branchSection(_ branch: BranchTagSetting) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { branch.enabled },
                set: { on in Task { await model.setBranchTag(enabled: on, color: branch.color) } }
            )) {
                HStack(spacing: 8) {
                    Text("Show")
                    TagChip(name: "main", color: branch.color, isBranch: true)
                }
            }
            .tint(Theme.accent)
            TagColorPresetGrid(selected: branch.color, isEnabled: !model.isSaving) { hex in
                Task { await model.setBranchTag(enabled: branch.enabled, color: hex) }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Branch tag")
        } footer: {
            Text("Show the git branch each conversation started on as a tag after its title.")
        }
    }

    // MARK: - Tags

    /// One scope's tags, in its order. In edit mode each row has a drag
    /// handle; a drop sends the scope's new order. A drag never leaves its
    /// scope — each scope is its own `ForEach`.
    @ViewBuilder
    private func tagRows(scope: Int?) -> some View {
        let tags = model.scopeTags(scope)
        if tags.isEmpty {
            Text("No tags here yet.")
                .font(.subheadline)
                .foregroundStyle(Theme.textTertiary)
        } else {
            ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                tagRow(tag, canMoveUp: index > 0, canMoveDown: index < tags.count - 1)
            }
            .onMove { source, destination in
                // The handles stay put while a change is out (the list is
                // disabled then); a drop that slips in meanwhile goes back.
                _ = model.reorder(scope: scope, fromOffsets: source, toOffset: destination)
            }
        }
    }

    private func tagRow(_ tag: ConversationTag, canMoveUp: Bool, canMoveDown: Bool) -> some View {
        Button {
            form = TagForm(tag: tag, scope: tag.folderId)
        } label: {
            HStack(spacing: 10) {
                TagChip(name: tag.name, color: tag.color)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Edit tag “\(tag.name)”"))
        .contextMenu {
            Button {
                form = TagForm(tag: tag, scope: tag.folderId)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                Task { await model.move(tag, by: -1) }
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(!canMoveUp)
            Button {
                Task { await model.move(tag, by: 1) }
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(!canMoveDown)
            Divider()
            Button(role: .destructive) {
                deleting = tag
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleting = tag
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func addButton(scope: Int?) -> some View {
        Button {
            form = TagForm(tag: nil, scope: scope)
        } label: {
            Label("New tag", systemImage: "plus")
                .foregroundStyle(Theme.accent)
        }
    }
}

/// The tag a form creates (in `scope`) or edits (`tag`).
struct TagForm: Identifiable {
    let id = UUID()
    let tag: ConversationTag?
    let scope: Int?
}

/// New tag / Edit tag: a name, a colour (a preset or `#rrggbb`), a preview, and
/// the server's reason when it refuses.
struct TagFormSheet: View {
    let form: TagForm
    let model: TagsManagerModel

    @State private var name: String
    @State private var color: String
    @State private var custom: String
    @Environment(\.dismiss) private var dismiss

    init(form: TagForm, model: TagsManagerModel) {
        self.form = form
        self.model = model
        let initial = form.tag?.color ?? model.suggestedColor(for: form.scope)
        _name = State(initialValue: form.tag?.name ?? "")
        _color = State(initialValue: initial)
        _custom = State(initialValue: initial)
    }

    private var normalized: String? { ConversationTags.normalizeColor(color) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The custom field half-typed (or wrong) would otherwise save the last
    /// valid colour without saying so.
    private var canSave: Bool {
        !trimmedName.isEmpty && normalized != nil && ConversationTags.normalizeColor(custom) != nil && !model.isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. bug, review, idea", text: $name)
                        .textInputAutocapitalization(.never)
                        .onChange(of: name) { _, value in
                            // The server keeps 64; don't let the field promise more.
                            if value.unicodeScalars.count > ConversationTags.maxNameLength {
                                var scalars = String.UnicodeScalarView()
                                scalars.append(contentsOf: value.unicodeScalars.prefix(ConversationTags.maxNameLength))
                                name = String(scalars)
                            }
                        }
                }
                Section("Color") {
                    TagColorPresetGrid(selected: color) { hex in
                        color = hex
                        custom = hex
                    }
                    .padding(.vertical, 4)
                    TextField("Custom color (#rrggbb)", text: $custom)
                        .font(.mono(14))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: custom) { _, value in
                            if let hex = ConversationTags.normalizeColor(value) { color = hex }
                        }
                        .foregroundStyle(ConversationTags.normalizeColor(custom) == nil ? Theme.danger : Theme.textPrimary)
                }
                if !trimmedName.isEmpty, let normalized {
                    Section {
                        TagChip(name: ConversationTags.cappedName(name), color: normalized)
                    }
                }
                if let error = model.error {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CodegBackground())
            .navigationTitle(form.tag == nil ? Text("New tag") : Text("Edit tag"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button { save() } label: {
                            form.tag == nil ? Text("Create") : Text("Save")
                        }
                        .disabled(!canSave)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
        .onDisappear { model.dismissError() }
    }

    private func save() {
        guard canSave, let normalized else { return }
        Task {
            let saved: Bool
            if let tag = form.tag {
                saved = await model.update(tag, name: name, color: normalized)
            } else {
                saved = await model.create(scope: form.scope, name: name, color: normalized)
            }
            if saved { dismiss() }
        }
    }
}
