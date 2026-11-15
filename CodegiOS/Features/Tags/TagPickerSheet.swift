import SwiftUI
import Combine

/// A conversation's tags (web `ConversationTagPickerPanel`): search, toggle,
/// and create a tag from the search text — global, or in the conversation's
/// folder (a worktree's are its repo's). Grouped Global / its folder / Other
/// folders, the last only for tags already on it from elsewhere (after a move),
/// so they can come off. Each toggle shows at once; the writes go out one at a
/// time through the conversation's one writer (``TagWriteRegistry``).
///
/// Presented from a Chats row's context menu and from the session screen's
/// "…" menu. "Manage tags…" pushes the manager inside the same sheet.
struct TagPickerSheet: View {
    let conversation: ConversationSummary
    let client: CodegClient

    @State private var model = TagPickerModel()
    @State private var query = ""
    /// Bumped on each tap, for the haptic (tied to the action, not the write).
    @State private var toggleTick = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                content
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        TagsManagerView(client: client)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Manage tags…")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search or create a tag…")
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
        .sensoryFeedback(.selection, trigger: toggleTick)
        .onAppear { model.open(conversation, api: client, endpoint: client.tagEndpoint) }
        .onDisappear { model.close() }
        // Back from the manager (or another window's edit): read the
        // definitions again so a renamed / recoloured / deleted tag shows so.
        .onReceive(NotificationCenter.default.publisher(for: .conversationTagDefinitionsDidChange)) { _ in
            model.refreshTags()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let tags = model.tags {
            list(tags)
        } else {
            ProgressView().tint(Theme.accent)
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func list(_ tags: [ConversationTag]) -> some View {
        let needle = trimmedQuery.lowercased()
        let visible: (ConversationTag) -> Bool = { needle.isEmpty || $0.name.lowercased().contains(needle) }
        let scope = model.scope
        let desired = model.desired
        let global = tags.filter { $0.folderId == nil && visible($0) }.sorted(by: ConversationTags.precedes)
        let own = scope == nil ? [] : tags.filter { $0.folderId == scope && visible($0) }.sorted(by: ConversationTags.precedes)
        let other = tags.filter {
            $0.folderId != nil && $0.folderId != scope && desired.contains($0.id) && visible($0)
        }.sorted(by: ConversationTags.precedes)
        let name = trimmedQuery
        let offerGlobal = !name.isEmpty && ConversationTags.find(named: name, scope: nil, in: tags) == nil
        let offerFolder = !name.isEmpty && scope != nil && ConversationTags.find(named: name, scope: scope, in: tags) == nil
        let nothingListed = global.isEmpty && own.isEmpty && other.isEmpty

        return List {
            Section {
                (conversation.trimmedTitle.map { Text(verbatim: $0) } ?? Text("Untitled session"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .listRowBackground(Color.clear)
                if let error = model.error {
                    errorRow(error)
                }
                if tags.isEmpty && name.isEmpty {
                    hint("No tags yet. Type a name to create one.")
                } else if nothingListed && !offerGlobal && !offerFolder {
                    hint("No matching tags")
                }
            }

            if !global.isEmpty {
                Section("Global") {
                    ForEach(global) { toggleRow($0, on: desired.contains($0.id)) }
                }
            }
            if !own.isEmpty {
                Section {
                    ForEach(own) { toggleRow($0, on: desired.contains($0.id)) }
                } header: {
                    folderHeader
                }
            }
            if !other.isEmpty {
                Section("Other folders") {
                    ForEach(other) { toggleRow($0, on: true) }
                }
            }
            if offerGlobal || offerFolder {
                Section {
                    if offerGlobal {
                        createRow(Text("Create global tag “\(name)”")) {
                            model.create(name: name, global: true)
                            query = ""
                        }
                    }
                    if offerFolder {
                        createRow(Text("Create “\(name)” in \(model.scopeName ?? String(localized: "This folder"))")) {
                            model.create(name: name, global: false)
                            query = ""
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private var folderHeader: some View {
        if let name = model.scopeName {
            Text(verbatim: name)
        } else {
            Text("This folder")
        }
    }

    private func toggleRow(_ tag: ConversationTag, on: Bool) -> some View {
        Button {
            toggleTick &+= 1
            model.toggle(tag)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(on ? Theme.accent : Theme.textTertiary)
                TagChip(name: tag.name, color: tag.color)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isReady)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func createRow(_ label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                label
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(model.isCreating ? Theme.textTertiary : Theme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isCreating || !model.isReady)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.danger)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }
}
