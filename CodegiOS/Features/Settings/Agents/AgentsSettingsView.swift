import SwiftUI

/// The server's agents: a reorderable list (drag in edit mode → `acp_reorder_agents`)
/// where each row carries an instant enable toggle and taps through to a detail
/// for env / model-provider / preflight. The toggle flips enabled immediately
/// (the row content, not the toggle, owns the tap that navigates).
struct AgentsSettingsView: View {
    let client: CodegClient?
    @State private var model: AgentsSettingsModel
    @State private var pushedAgentType: AgentType?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(client: CodegClient?) {
        self.client = client
        _model = State(initialValue: AgentsSettingsModel(client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        // A standard large title (matches Experts / Skills): big at the top on
        // compact, collapsing to a centered inline title as the list scrolls.
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(horizontalSizeClass == .compact ? .large : .automatic)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.agents.count > 1 { EditButton().tint(Theme.accent) }
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.snappy(duration: 0.25), value: model.toast)
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if model.agents.isEmpty {
            switch model.phase {
            case .loading:
                LoadingView(label: "Loading agents…")
            case .failed(let message):
                InlineErrorView(message: message) { Task { await model.load() } }
            case .loaded:
                EmptyStateView(icon: "cpu", title: "No Agents", message: "This server has no registered agents.")
            }
        } else {
            List {
                if let error = model.refreshError {
                    RefreshErrorBanner(
                        message: error,
                        retry: { Task { await model.load() } },
                        dismiss: { model.refreshError = nil }
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: Theme.Layout.screenHMargin, bottom: 8, trailing: Theme.Layout.screenHMargin))
                }
                ForEach(model.agents) { agent in
                    AgentRow(agent: agent, model: model) { pushedAgentType = agent.agentType }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: Theme.Layout.screenHMargin, bottom: 5, trailing: Theme.Layout.screenHMargin))
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
            // Row content taps set `pushedAgent`; this drives the push (an explicit
            // item destination, so the row's trailing Toggle stays independent of
            // navigation — a NavigationLink label would swallow the toggle's taps).
            // Push by agent type; the detail reads the LIVE agent from the model so
            // a save/install reload is reflected without a stale snapshot.
            .navigationDestination(item: $pushedAgentType) { type in
                AgentDetailView(model: model, agentType: type, client: client)
            }
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
                    // Don't clear a newer toast: if this task was cancelled by a
                    // toast change, the replacement task owns the dismissal.
                    if !Task.isCancelled { model.toast = nil }
                }
        }
    }
}

/// One agent row: brand avatar, name + install-status pill, description, and an
/// instant enable toggle. Tapping the content (not the toggle) opens the detail.
private struct AgentRow: View {
    let agent: AcpAgentInfo
    let model: AgentsSettingsModel
    let onOpen: () -> Void

    var body: some View {
        GlassCard(cornerRadius: Theme.Radius.md, padding: 12) {
            HStack(spacing: 12) {
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        AgentAvatar(agent: agent.agentType, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(agent.name)
                                    .font(.headline)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                AgentStatusPill(agent: agent)
                            }
                            if !agent.description.isEmpty {
                                Text(agent.description)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Toggle("", isOn: Binding(
                    get: { agent.enabled },
                    set: { on in Task { _ = await model.setEnabled(agent, on) } }
                ))
                .labelsHidden()
                .tint(Theme.accent)
                // The agent name sits in the adjacent button, so label the switch
                // explicitly for VoiceOver.
                .accessibilityLabel("\(agent.name) enabled")
                .disabled(!agent.available || model.togglingEnabled.contains(agent.agentType))
            }
        }
        .contentShape(Rectangle())
    }
}

/// A small status pill reflecting an agent's install state: its version when
/// installed (accent), "Not installed" when available but absent (neutral), or
/// "Unavailable" when the platform can't run it (danger).
struct AgentStatusPill: View {
    let agent: AcpAgentInfo

    private var label: LocalizedStringKey {
        if !agent.available { return "Unavailable" }
        if let v = agent.installedVersion { return "v\(v)" }
        return "Not installed"
    }

    private var tint: Color {
        if !agent.available { return Theme.danger }
        return agent.installedVersion != nil ? Theme.accent : Theme.textTertiary
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }
}
