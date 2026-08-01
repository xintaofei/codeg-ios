import SwiftUI

/// Custom OpenAI-compatible model-provider endpoints, grouped by agent. List +
/// add / edit / delete; no reordering, so it uses the ScrollView + LazyVStack
/// glass pattern. Tapping a row opens its editor; long-press offers edit / delete.
struct ModelProvidersSettingsView: View {
    @State private var model: ModelProvidersSettingsModel
    @State private var editorRoute: EditorRoute?
    @State private var pendingDelete: ModelProviderInfo?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum EditorRoute: Identifiable {
        case add
        case edit(ModelProviderInfo)
        var id: String {
            switch self {
            case .add: "add"
            case .edit(let p): "edit-\(p.id)"
            }
        }
    }

    init(client: CodegClient?) {
        _model = State(initialValue: ModelProvidersSettingsModel(client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        // A standard large title (matches Experts / Skills / Agents): big at the
        // top on compact, collapsing to a centered inline title as the list
        // scrolls. iPad keeps the system default for a detail pane.
        .navigationTitle("Model Providers")
        .navigationBarTitleDisplayMode(horizontalSizeClass == .compact ? .large : .automatic)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editorRoute = .add } label: { Image(systemName: "plus") }
                    .tint(Theme.accent)
                    .accessibilityLabel("Add Model Provider")
            }
        }
        .sheet(item: $editorRoute) { editorSheet($0) }
        .confirmationDialog(
            "Delete Provider",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { provider in
            Button("Delete \(provider.name)", role: .destructive) {
                Task { await model.delete(provider) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { provider in
            Text("Remove “\(provider.name)”. Running sessions that use it must be restarted.")
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.snappy(duration: 0.25), value: model.toast)
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            switch model.phase {
            case .loading:
                LoadingView(label: "Loading providers…")
            case .failed(let message):
                InlineErrorView(message: message) { Task { await model.load() } }
            case .loaded:
                EmptyStateView(
                    icon: "server.rack",
                    title: "No Model Providers",
                    message: "Add a custom OpenAI-compatible endpoint to route an agent through your own model.",
                    actionTitle: "Add Provider",
                    action: { editorRoute = .add }
                )
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let error = model.refreshError {
                        RefreshErrorBanner(
                            message: error,
                            retry: { Task { await model.load() } },
                            dismiss: { model.refreshError = nil }
                        )
                    }
                    ForEach(model.grouped, id: \.agent) { group in
                        Text("\(group.agent.displayName.uppercased()) · \(group.items.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .tracking(0.5)
                            .padding(.top, 6)
                            .padding(.leading, 4)
                        ForEach(group.items) { provider in
                            ModelProviderRow(provider: provider)
                                .contentShape(.rect)
                                .onTapGesture { editorRoute = .edit(provider) }
                                .contextMenu {
                                    Button { editorRoute = .edit(provider) } label: { Label("Edit", systemImage: "pencil") }
                                    Divider()
                                    Button(role: .destructive) { pendingDelete = provider } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .codegGlassEffect(tint: Theme.accent.opacity(0.18), in: Capsule())
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(3.5))
                    // Don't clear a newer toast (the replacement task dismisses it).
                    if !Task.isCancelled { model.toast = nil }
                }
        }
    }

    @ViewBuilder
    private func editorSheet(_ route: EditorRoute) -> some View {
        switch route {
        case .add:
            ModelProviderEditorSheet(editing: nil) { name, apiUrl, apiKey, agentType, model in
                try await self.model.create(name: name, apiUrl: apiUrl, apiKey: apiKey, agentType: agentType, model: model)
            } onUpdate: { _ in }
        case .edit(let provider):
            ModelProviderEditorSheet(editing: provider) { _, _, _, _, _ in
            } onUpdate: { body in
                try await self.model.update(body)
            }
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

/// One provider card: the agent's brand avatar, the provider name, its configured
/// model (when set), and the API endpoint — with a chevron hinting it opens. The
/// agent itself is carried by the enclosing section header + the avatar; the
/// masked key never appears inline (it lives in the editor).
private struct ModelProviderRow: View {
    let provider: ModelProviderInfo

    var body: some View {
        GlassCard(cornerRadius: Theme.Radius.md, padding: 13) {
            HStack(spacing: 13) {
                AgentAvatar(agent: provider.agentType, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let summary = modelSummary {
                        HStack(spacing: 5) {
                            Image(systemName: "cpu")
                                .font(.caption2)
                                .foregroundStyle(Theme.accent)
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "network")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                        Text(provider.apiUrl)
                            .font(.mono(11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .contentShape(Rectangle())
    }

    /// A compact summary of the provider's configured model(s), or nil when it
    /// uses the provider default. For Claude Code the `model` field is a per-role
    /// JSON object (`{main,reasoning,haiku,sonnet,opus}`): prefer the `main`
    /// model, appending `+N` for any other overrides; if `main` is unset show the
    /// lone override or an "N model overrides" count. Other agents store a plain
    /// model name. Reads only `model` — never any key material.
    private var modelSummary: String? {
        if provider.agentType == .claudeCode {
            let m = ClaudeProviderModel.parse(provider.model)
            let set = [m.main, m.reasoning, m.haiku, m.sonnet, m.opus].filter { !$0.isEmpty }
            guard !set.isEmpty else { return nil }
            if !m.main.isEmpty {
                return set.count == 1 ? m.main : "\(m.main) +\(set.count - 1)"
            }
            return set.count == 1 ? set[0] : "\(set.count) model overrides"
        } else {
            let trimmed = (provider.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
