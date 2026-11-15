import SwiftUI

/// Installed MCP servers: each row shows the server id and which agent apps it's
/// enabled for. Add/edit a server (id + JSON spec + per-app toggles); delete.
struct McpSettingsView: View {
    @State private var model: McpSettingsModel
    @State private var editorRoute: EditorRoute?
    @State private var pendingDelete: LocalMcpServer?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum EditorRoute: Identifiable {
        case add
        case edit(LocalMcpServer)
        var id: String {
            switch self {
            case .add: "add"
            case .edit(let s): "edit-\(s.id)"
            }
        }
    }

    init(client: CodegClient?) {
        _model = State(initialValue: McpSettingsModel(client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .screenTitle("MCP", compact: horizontalSizeClass == .compact)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editorRoute = .add } label: { Image(systemName: "plus") }
                    .tint(Theme.accent)
                    .accessibilityLabel("Add MCP Server")
            }
        }
        .sheet(item: $editorRoute) { editorSheet($0) }
        .confirmationDialog(
            "Remove MCP Server",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { server in
            Button("Remove \(server.id)", role: .destructive) {
                Task { await model.remove(server) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text("Remove the MCP server “\(server.id)” from all apps it's assigned to.")
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if model.servers.isEmpty, model.sourceWarnings.isEmpty {
            switch model.phase {
            case .loading:
                LoadingView(label: "Loading MCP servers…")
            case .failed(let message):
                InlineErrorView(message: message) { Task { await model.load() } }
            case .loaded:
                EmptyStateView(
                    icon: "puzzlepiece.extension",
                    title: "No MCP Servers",
                    message: "Add a Model Context Protocol server to extend your agents with tools.",
                    actionTitle: "Add MCP Server",
                    action: { editorRoute = .add }
                )
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let error = model.refreshError {
                        RefreshErrorBanner(
                            message: error,
                            retry: { Task { await model.load() } },
                            dismiss: { model.refreshError = nil }
                        )
                    }
                    // One agent's config being unreadable hides only that
                    // agent's servers — the rest of the list is still real.
                    ForEach(model.sourceWarnings, id: \.self) { warning in
                        McpSourceWarningBanner(warning: warning)
                    }
                    ForEach(model.servers) { server in
                        McpServerRow(server: server)
                            .contentShape(.rect)
                            .onTapGesture { editorRoute = .edit(server) }
                            .contextMenu {
                                Button { editorRoute = .edit(server) } label: { Label("Edit", systemImage: "pencil") }
                                Divider()
                                Button(role: .destructive) { pendingDelete = server } label: { Label("Remove", systemImage: "trash") }
                            }
                    }
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 2)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }

    @ViewBuilder
    private func editorSheet(_ route: EditorRoute) -> some View {
        switch route {
        case .add:
            McpServerEditorSheet(editing: nil, saveBlocked: !model.sourceWarnings.isEmpty) { id, spec, apps in
                try await model.upsert(serverId: id, spec: spec, apps: apps)
            }
        case .edit(let server):
            McpServerEditorSheet(editing: server, saveBlocked: !model.sourceWarnings.isEmpty) { id, spec, apps in
                try await model.upsert(serverId: id, spec: spec, apps: apps)
            }
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

/// An agent whose MCP config the scan couldn't read (web `sourceUnreadable`).
private struct McpSourceWarningBanner: View {
    let warning: LocalMcpSourceWarning

    var body: some View {
        Label {
            Text("Couldn’t read the MCP config for \(warning.app.displayName), so its servers are hidden: \(warning.message)")
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
}

/// One MCP server card: transport badge + id, the command/url it runs, and the
/// apps it's enabled for — enough to identify a server without opening it.
private struct McpServerRow: View {
    let server: LocalMcpServer

    var body: some View {
        GlassCard(cornerRadius: Theme.Radius.md, padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(server.id)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    TransportBadge(label: server.transportLabel)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }

                Text(server.specSummary)
                    .font(.mono(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if server.apps.isEmpty {
                    Label("Not assigned to any app", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.danger.opacity(0.9))
                } else {
                    FlowChips(labels: server.apps.map(\.displayName))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A small accent pill naming the MCP transport (Stdio / HTTP / SSE).
private struct TransportBadge: View {
    let label: String

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.accentDim, in: Capsule())
    }
}

/// Minimal wrapping chip row (avoids pulling in a layout dependency).
private struct FlowChips: View {
    let labels: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels.prefix(4), id: \.self) { label in
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            if labels.count > 4 {
                Text("+\(labels.count - 4)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
