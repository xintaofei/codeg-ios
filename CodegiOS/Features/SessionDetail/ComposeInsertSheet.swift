import SwiftUI

/// The "+" menu's insert picker: a searchable list for one of Quick Messages /
/// Expert Skills / Slash Commands. Selecting a row emits a pure draft transform
/// (`onInsert`) the compose bar applies to its text, then dismisses — mirroring
/// the web add-menu's submenus.
struct ComposeInsertSheet: View {
    let source: ComposeInsertModel.Source
    let model: ComposeInsertModel
    /// Emits a transform `(currentDraft) -> newDraft` for the picked item.
    let onInsert: (@escaping (String) -> String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                content
            }
            .navigationTitle(source.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Theme.accent)
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
        .task { model.load(source) }
    }

    // MARK: - State routing

    @ViewBuilder
    private var content: some View {
        let phase = model.phase(source)
        if model.isEmpty(source), phase == .loading {
            centered { ProgressView().tint(Theme.accent) }
        } else if case .failed(let message) = phase, model.isEmpty(source) {
            failed(message)
        } else if phase == .loaded, model.isEmpty(source) {
            emptyState
        } else {
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        List {
            switch source {
            case .quickMessages:
                let items = filteredQuickMessages
                if items.isEmpty { noMatchesRow } else {
                    ForEach(items) { item in
                        row(title: item.title.isEmpty ? "Untitled" : item.title,
                            subtitle: item.content,
                            token: nil) {
                            onInsert { model.draftAppendingMessage(item.content, to: $0) }
                            dismiss()
                        }
                    }
                }
            case .experts:
                let items = filteredExperts
                if items.isEmpty { noMatchesRow } else {
                    ForEach(items) { item in
                        row(title: item.metadata.localizedName,
                            subtitle: item.metadata.localizedDescription,
                            token: "\(model.expertPrefix)\(item.metadata.id)") {
                            onInsert { model.draftApplyingExpert(item.metadata.id, to: $0) }
                            dismiss()
                        }
                    }
                }
            case .slashCommands:
                let items = filteredCommands
                if items.isEmpty { noMatchesRow } else {
                    ForEach(items) { item in
                        row(title: ComposerInvocations.commandInvocationToken(item.name),
                            subtitle: item.description,
                            token: ComposerInvocations.commandInputHint(item),
                            monospacedTitle: true) {
                            onInsert { model.draftAppendingCommand(item.name, to: $0) }
                            dismiss()
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(title: String, subtitle: String?, token: String?, monospacedTitle: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(monospacedTitle ? .callout.monospaced().weight(.medium) : .callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let token, !token.isEmpty {
                        Text(token)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Theme.hairline)
    }

    private var noMatchesRow: some View {
        Text("No matches")
            .font(.callout)
            .foregroundStyle(Theme.textTertiary)
            .listRowBackground(Color.clear)
    }

    // MARK: - Empty / failed states

    private var emptyState: some View {
        centered {
            VStack(spacing: 8) {
                Image(systemName: source.systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textTertiary)
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
        }
    }

    private var emptyMessage: LocalizedStringKey {
        switch source {
        case .quickMessages: return "No quick messages yet. Create them on the codeg web app."
        case .experts: return "No experts are linked to this agent."
        case .slashCommands: return "No slash commands yet — they appear once the session is active."
        }
    }

    private func failed(_ message: String) -> some View {
        centered {
            VStack(spacing: 10) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { model.load(source) }
                    .buttonStyle(.glass)
                    .tint(Theme.accent)
            }
            .padding(.horizontal, 32)
        }
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filtering

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private var filteredQuickMessages: [QuickMessage] {
        guard !query.isEmpty else { return model.quickMessages }
        return model.quickMessages.filter {
            $0.title.lowercased().contains(query) || $0.content.lowercased().contains(query)
        }
    }

    private var filteredExperts: [ExpertListItem] {
        guard !query.isEmpty else { return model.experts }
        return model.experts.filter {
            $0.metadata.localizedName.lowercased().contains(query)
                || $0.metadata.id.lowercased().contains(query)
                || ($0.metadata.localizedDescription?.lowercased().contains(query) ?? false)
        }
    }

    /// Ranked like the web add-menu's `filteredSlashCommands`: the shared
    /// `rankByTextMatch` over the name, the description as a fallback that
    /// always ranks below any name hit.
    private var filteredCommands: [AvailableCommandInfo] {
        FuzzyTextMatch.rank(search, model.visibleCommands, primary: { $0.name }, secondary: { $0.description })
    }
}
