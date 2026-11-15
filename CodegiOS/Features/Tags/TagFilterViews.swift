import SwiftUI

/// The Chats list's tag filter, kept per server profile (tag ids are a
/// server's own) in `UserDefaults`. An inactive filter is stored as nothing.
enum TagFilterStore {
    private static func key(_ server: String) -> String { "codeg.tagFilter.\(server)" }

    static func load(server: String, defaults: UserDefaults = .standard) -> TagFilter {
        guard let data = defaults.data(forKey: key(server)),
              let filter = try? JSONDecoder().decode(TagFilter.self, from: data) else { return .none }
        return filter
    }

    static func save(_ filter: TagFilter, server: String, defaults: UserDefaults = .standard) {
        if filter.isActive, let data = try? JSONEncoder().encode(filter) {
            defaults.set(data, forKey: key(server))
        } else {
            defaults.removeObject(forKey: key(server))
        }
    }
}

/// Filter the Chats list by tags (web `TagFilterPanel`): match any or all, the
/// tags grouped Global then by folder, each with how many listed conversations
/// carry it. Reads the list's model directly, so every change shows at once.
struct TagFilterSheet: View {
    let viewModel: SessionListViewModel
    let client: CodegClient

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                list
            }
            .navigationTitle("Filter by tags")
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
            .modifier(SearchWhenLong(isLong: viewModel.tags.count > 8, query: $query))
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
    }

    private var filter: TagFilter { viewModel.activeFilter }

    /// How many listed conversations carry each tag.
    private var counts: [Int: Int] {
        var out: [Int: Int] = [:]
        for conversation in viewModel.conversations {
            for id in conversation.tagIds { out[id, default: 0] += 1 }
        }
        return out
    }

    /// One heading's tags: Global (`folderName` nil) or one folder's.
    private struct TagGroup: Identifiable {
        let id: String
        let folderName: String?
        let tags: [ConversationTag]
    }

    /// Global first, then each folder's tags under its name (A–Z).
    private var groups: [TagGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = viewModel.tags.filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
        var out: [TagGroup] = []
        let global = visible.filter { $0.folderId == nil }.sorted(by: ConversationTags.precedes)
        if !global.isEmpty { out.append(TagGroup(id: "global", folderName: nil, tags: global)) }
        let byFolder = Dictionary(grouping: visible.filter { $0.folderId != nil }) { $0.folderId ?? 0 }
        let named: [TagGroup] = byFolder.map { id, tags in
            TagGroup(id: "folder-\(id)",
                     folderName: viewModel.folders.first { $0.id == id }?.name ?? "#\(id)",
                     tags: tags.sorted(by: ConversationTags.precedes))
        }
        out.append(contentsOf: named.sorted {
            ($0.folderName ?? "").localizedCaseInsensitiveCompare($1.folderName ?? "") == .orderedAscending
        })
        return out
    }

    private var list: some View {
        let counts = self.counts
        let groups = self.groups
        return List {
            if viewModel.tags.isEmpty {
                Text("No tags yet. Add one from a conversation's menu.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Section {
                    Picker("Match", selection: modeBinding) {
                        Text("Any").tag(TagFilterMode.matchAny)
                        Text("All").tag(TagFilterMode.matchAll)
                    }
                    .pickerStyle(.segmented)
                    if filter.isActive {
                        Button("Clear filter") { viewModel.setTagFilter(.none) }
                            .foregroundStyle(Theme.accent)
                    }
                } footer: {
                    filter.mode == .matchAll
                        ? Text("Conversations with every selected tag")
                        : Text("Conversations with at least one of the selected tags")
                }
                if groups.isEmpty {
                    Text("No matching tags")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.tags) { tag in
                            row(tag, count: counts[tag.id] ?? 0)
                        }
                    } header: {
                        if let name = group.folderName {
                            Text(verbatim: name)
                        } else {
                            Text("Global")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var modeBinding: Binding<TagFilterMode> {
        Binding(
            get: { filter.mode },
            set: { mode in
                var next = viewModel.activeFilter
                next.mode = mode
                viewModel.setTagFilter(next)
            }
        )
    }

    private func row(_ tag: ConversationTag, count: Int) -> some View {
        let on = filter.tagIDs.contains(tag.id)
        return Button {
            viewModel.setTagFilter(viewModel.activeFilter.toggling(tag.id))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(on ? Theme.accent : Theme.textTertiary)
                TagChip(name: tag.name, color: tag.color)
                Spacer(minLength: 8)
                Text(verbatim: "\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A search field only once there are enough tags to need one (web: past 8).
private struct SearchWhenLong: ViewModifier {
    let isLong: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if isLong {
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                               prompt: "Search tags…")
        } else {
            content
        }
    }
}

/// The strip over a filtered list (web `SidebarTagFilterBar`): the picked
/// tags, each removable, how they combine when there are several, and Clear.
struct TagFilterBar: View {
    let filter: TagFilter
    let tagsByID: [Int: ConversationTag]
    let onChange: (TagFilter) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if filter.tagIDs.count > 1 {
                        (filter.mode == .matchAll ? Text("Match all") : Text("Match any"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(filter.tagIDs.compactMap { tagsByID[$0] }) { tag in
                        Button {
                            onChange(filter.toggling(tag.id))
                        } label: {
                            HStack(spacing: 3) {
                                TagChip(name: tag.name, color: tag.color)
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Remove “\(tag.name)” from the filter"))
                    }
                }
            }
            Button("Clear filter") { onChange(.none) }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
    }
}
