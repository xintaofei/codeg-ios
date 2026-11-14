import SwiftUI

/// The "N running" chip above the composer, and the list it opens (web
/// `LiveRunsChip` / `LiveRunsGroups`): the connection's background tasks, the
/// agent's background sub-agents, and the codeg delegations still running (see
/// ``LiveRuns`` for where each comes from).
///
/// It stands for work that outlives the turn, so it stays between turns as long
/// as any of it runs. Reads ``ConnectionRunsModel`` in its own body — never the
/// screen's view model — so a running-list update re-renders this alone.
struct LiveRunsChip: View {
    let runs: ConnectionRunsModel
    /// The agent's display name, for the row of a turn it started on its own.
    let agentName: String

    @State private var showList = false

    var body: some View {
        let count = runs.liveRuns.count
        ZStack {
            if count > 0 {
                Button { showList = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .symbolEffect(.pulse)
                        Text("\(count) running")
                            .font(Theme.Typography.metaLabel.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.surfaceStroke, lineWidth: 0.75))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows what is running in the background"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .animation(Theme.Motion.expand, value: count > 0)
        // The list closes with the last row: there is nothing left to show.
        .onChange(of: count == 0) { _, empty in
            if empty { showList = false }
        }
        .sheet(isPresented: $showList, onDismiss: { runs.stopNotice = nil }) {
            LiveRunsSheet(runs: runs, agentName: agentName)
        }
    }
}

// MARK: - The list

private struct LiveRunsSheet: View {
    let runs: ConnectionRunsModel
    let agentName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.colorScheme) private var colorScheme

    /// Resolved straight off the store: the bridged accent trait behind
    /// `Theme.accent` does not reach a sheet's separate hosting controller.
    private var accent: Color { appearance.accent.fill(dark: colorScheme == .dark) }

    var body: some View {
        let live = runs.liveRuns
        NavigationStack {
            List {
                if let notice = runs.stopNotice {
                    Section {
                        Label {
                            Text(verbatim: notice)
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        } icon: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(Theme.warning)
                        }
                    }
                }
                if !live.tasks.isEmpty {
                    Section {
                        ForEach(live.tasks, id: \.taskId) { task in
                            AsyncTaskRunRow(
                                task: task,
                                agentName: agentName,
                                accent: accent,
                                stopping: runs.stoppingTaskIDs.contains(task.taskId),
                                onStop: { runs.stop(task.taskId) })
                        }
                    } header: {
                        GroupHeader(title: "Background tasks", count: live.tasks.count)
                    }
                }
                if !live.subagents.isEmpty {
                    Section {
                        ForEach(live.subagents) { run in
                            BackgroundSubAgentRow(run: run, accent: accent)
                        }
                    } header: {
                        GroupHeader(title: "Sub-agents", count: live.subagents.count)
                    }
                }
                if !live.delegations.isEmpty {
                    Section {
                        ForEach(live.delegations) { run in
                            DelegationRunRow(run: run, accent: accent)
                        }
                    } header: {
                        GroupHeader(title: "Delegations", count: live.delegations.count)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CodegBackground())
            .animation(Theme.Motion.expand, value: live)
            .navigationTitle(Text("\(live.count) running"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(accent)
        .presentationDetents([.medium, .large])
    }
}

private struct GroupHeader: View {
    let title: LocalizedStringKey
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(verbatim: "\(count)")
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

// MARK: - Rows

/// One live AIR async task (web `AsyncTaskRow`): what it is, the evidence it is
/// making progress (phase · agent · last tool · tokens), and its stop. A turn
/// the agent started on its own says who is working and why instead.
private struct AsyncTaskRunRow: View {
    let task: AsyncTaskRecord
    let agentName: String
    let accent: Color
    let stopping: Bool
    let onStop: () -> Void

    private var isTurn: Bool { task.taskType == AsyncTasks.autonomousTurnTaskType }
    private var paused: Bool { task.state == "paused" }

    /// The adapter's friendly `task_type` vocabulary; an unmapped future type
    /// keeps the generic glyph.
    private var symbol: String {
        if paused { return "pause.circle" }
        switch task.taskType {
        case "shell": return "apple.terminal"
        case "workflow": return "point.3.connected.trianglepath.dotted"
        case "monitor": return "waveform.path.ecg"
        case AsyncTasks.autonomousTurnTaskType: return "cpu"
        default: return "gearshape.2"
        }
    }

    private var title: String {
        isTurn ? String(localized: "\(agentName) is working") : task.name
    }

    private var meta: String? {
        let parts: [String?] = isTurn
            ? [LiveRunsText.turnCause(task.description)]
            : [task.phase, task.currentAgent, task.lastToolName,
               task.usage.map { String(localized: "\(LiveRuns.formatTokenCount($0.totalTokens)) tokens") }]
        // Grok clears with "" — present on the wire, but nothing to show.
        let shown = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return shown.isEmpty ? nil : shown.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(paused ? Theme.textTertiary : accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let meta {
                    Text(verbatim: meta)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if task.canStop {
                Button(action: onStop) {
                    ZStack {
                        // Both laid out so the button keeps its width while stopping.
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.titleAndIcon)
                            .opacity(stopping ? 0 : 1)
                        if stopping { ProgressView().controlSize(.mini) }
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.danger)
                .disabled(stopping)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One of the agent's background sub-agents: titled by its producer, aged by
/// the clock. The only ticking view on the list, and only while it is open.
private struct BackgroundSubAgentRow: View {
    let run: LiveRuns.SubAgentRun
    let accent: Color

    private var title: Text {
        if let description = run.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return Text(verbatim: description)
        }
        return Text("Sub-agent")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text("Background")
                    if let startedAtMs = run.startedAtMs {
                        Text(verbatim: "·")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(verbatim: LiveRunsText.elapsed(since: startedAtMs, now: context.date))
                        }
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// A codeg delegation: who runs it and what it was asked. No stop — that is
/// the parent agent's (`cancel_delegation`).
private struct DelegationRunRow: View {
    let run: LiveRuns.DelegationRun
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            if let info = run.binding?.info {
                AgentIcon(agent: info.agentType)
                    .frame(width: 18, height: 18)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name(info))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let task = info.taskPreview?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty {
                        Text(verbatim: task)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                    }
                }
            } else {
                // Its call could not be identified, so nothing names it but the
                // backend's word that it runs.
                Image(systemName: "person.2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 22)
                Text("Delegated sub-agent")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func name(_ info: DelegationInfo) -> String {
        if let assistant = info.assistantName?.trimmingCharacters(in: .whitespacesAndNewlines), !assistant.isEmpty {
            return assistant
        }
        return info.agentType.label
    }
}
