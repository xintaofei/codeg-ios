import SwiftUI

// Dedicated cards for the delegation companion tools, mirroring the web client's
// `delegated-sub-thread.tsx`, `delegation-status-*.tsx`, and
// `delegation-status-badge.tsx`. Status/state resolution lives in
// `DelegationModel`; these are presentation only.

// MARK: - Status badge

/// Status pill for a delegation card / row. Named to avoid colliding with the
/// existing `StatusBadge` (conversation status) in `DesignSystem/Badges.swift`.
struct CompanionStatusBadge: View {
    let status: BadgeStatus
    var errorCode: String?

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(label).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .starting:
            Image(systemName: "circle.dashed").font(.system(size: 9, weight: .bold))
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
        case .waiting:
            Image(systemName: "exclamationmark.shield.fill").font(.system(size: 9, weight: .bold))
        case .checked:
            Image(systemName: "clock").font(.system(size: 9, weight: .bold))
        case .ok:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 9, weight: .bold))
        case .err:
            Image(systemName: "xmark.circle.fill").font(.system(size: 9, weight: .bold))
        }
    }

    private var tint: Color {
        switch status {
        case .starting, .checked: return Theme.textTertiary
        case .running: return Theme.accent
        case .waiting: return Theme.warning
        case .ok: return DiffPalette.addText
        case .err: return Theme.danger
        }
    }

    private var label: LocalizedStringKey {
        switch status {
        case .starting: return "Starting"
        case .running:  return "Running"
        case .waiting:  return "Waiting"
        case .checked:  return "Checked"
        case .ok:       return "Done"
        case .err:      return Self.errorLabel(errorCode)
        }
    }

    /// Wire-stable error code → short badge label. Mirrors web `ErrorLabel`.
    static func errorLabel(_ code: String?) -> LocalizedStringKey {
        switch code {
        case "delegation_disabled":     return "Delegation off"
        case "depth_limit":             return "Depth limit"
        case "invalid_agent_type":      return "Invalid agent"
        case "spawn_failed":            return "Spawn failed"
        case "send_failed":             return "Send failed"
        case "timeout":                 return "Timed out"
        case "canceled":                return "Canceled"
        case "child_refusal":           return "Refused"
        case "child_max_tokens":        return "Max tokens"
        case "child_max_turn_requests": return "Max turns"
        case "child_empty":             return "No output"
        case "child_unknown", "unknown": return "Unknown task"
        default:                        return "Failed"
        }
    }
}

// MARK: - delegate_to_agent

/// A self-contained card for a `delegate_to_agent` call: agent avatar + label,
/// the broker `#taskId`, a status badge, and the delegated task text. Status-only
/// (iOS has no sub-agent session viewer), so unlike the web there is no
/// "View session" affordance.
struct DelegatedSubThreadCard: View {
    let vm: ToolCallVM

    var body: some View {
        // The broker-written `meta["codeg.delegation"]` is the authoritative
        // terminal status: under async delegation the tool output is only a
        // running ack, so without the meta the card would read "Running" forever
        // even after the child finished. It also carries the elapsed time.
        let meta = DelegationModel.parseDelegationMeta(vm.meta)
        // An opencode code-mode `execute` carries its arguments inside its JS
        // `code`; `parseInput` reads them from there too.
        let input = DelegationModel.parseInput(vm.input)
        let toolOutput = DelegationModel.parseToolOutput(vm.output, forceError: vm.isError)
        let hasError = vm.isError || vm.state == .error
        let status = DelegationModel.resolveStatus(parsedMeta: meta, toolOutput: toolOutput, state: vm.state, hasError: hasError)
        let taskId = DelegationModel.parseDelegateTaskId(output: vm.output, errorText: nil) ?? meta?.taskId
        let duration = meta?.durationMs.map { DelegationModel.formatDuration($0) }

        HStack(alignment: .top, spacing: 10) {
            avatar(input.agentType)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: input.agentType?.label ?? String(localized: "Sub-agent"))
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let taskId {
                        Text(verbatim: "#" + taskId.prefix(8))
                            .font(.mono(10.5)).foregroundStyle(Theme.textTertiary)
                    }
                    if let duration {
                        Text(verbatim: duration)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    CompanionStatusBadge(status: badgeStatus(status), errorCode: meta?.errorCode)
                }
                if let task = input.task, !task.isEmpty {
                    Text(verbatim: task)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
    }

    @ViewBuilder private func avatar(_ agent: AgentType?) -> some View {
        if let agent {
            AgentAvatar(agent: agent, size: 34)
        } else {
            Image(systemName: "person.fill.questionmark")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 34, height: 34)
                .background(Theme.surfaceNested, in: Circle())
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    private func badgeStatus(_ s: DelegationCardStatus) -> BadgeStatus {
        switch s {
        case .starting: return .starting
        case .running:  return .running
        case .waiting:  return .waiting
        case .ok:       return .ok
        case .err:      return .err
        }
    }
}

// MARK: - resume_delegation (refused)

/// A `resume_delegation` the broker refused (`not_resumable`): the resume and
/// the broker's reason, read in place. The refusal still names the task's
/// agent, child and real status, but it revived nothing — so this card never
/// shows a sub-agent or a run state (web: the workbench row `Resuming task …`
/// that `DelegationResumeRow` falls back to; its reason, there one tap away,
/// is the point of the card here).
struct RefusedResumeCard: View {
    let vm: ToolCallVM
    let refusal: ResumeRefusal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                // A refusal delivered as an error is the call failing; an
                // ordinary one is an answer, which carries no status of its own.
                if vm.isError {
                    CompanionStatusBadge(status: .err)
                        .fixedSize()
                }
            }
            if let message = refusal.message {
                // The broker's own words (protocol English), verbatim.
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
    }

    private var title: LocalizedStringKey {
        guard let taskId = refusal.taskId else { return "Resuming a delegated task" }
        return "Resuming task #\(String(taskId.prefix(8)))"
    }
}

// MARK: - get_delegation_status (grouped) / cancel_delegation

/// One card for a run of `get_delegation_status` polls (one row per task), and —
/// with `kind: .cancel` and a single poll — the `cancel_delegation` card. Mirrors
/// web `DelegationStatusGroupCard` + `DelegationStatusCard`.
struct DelegationStatusGroupCard: View {
    let polls: [ToolCallVM]
    var kind: DelegationRowKind = .status

    var body: some View {
        let rows = DelegationModel.buildTaskRows(polls, kind: kind)
        if rows.isEmpty {
            EmptyView()
        } else {
            let allError = rows.allSatisfy { $0.badge.status == .err }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    if idx > 0 {
                        Divider().background(Theme.hairline)
                    }
                    DelegationStatusRow(kind: kind, taskId: row.taskId, report: row.report,
                                        badge: row.badge, results: row.results)
                        .background(rowTint(allError: allError, status: row.badge.status))
                }
            }
            .background(allError ? Theme.danger.opacity(0.06) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .hairlineBorder(Theme.Radius.md, color: allError ? Theme.danger.opacity(0.4) : Theme.hairline)
        }
    }

    private func rowTint(allError: Bool, status: BadgeStatus) -> Color {
        (!allError && status == .err) ? Theme.danger.opacity(0.06) : Color.clear
    }
}

/// One collapsible row of `DelegationStatusGroupCard`: intent label
/// ("Waiting for task #id's result" / "Canceling task #id"), `×N` poll count,
/// duration, status badge; expands to the Markdown result with a `< N / M >`
/// pager when polled more than once.
struct DelegationStatusRow: View {
    let kind: DelegationRowKind
    let taskId: String?
    let report: StatusReport
    let badge: ResolvedBadge
    var results: [String?] = []

    @State private var expanded = false
    /// nil = follow the latest result; a number = an explicitly navigated page.
    @State private var pageIdx: Int?

    private var effectiveResults: [String?] {
        results.isEmpty ? (report.text.map { [$0] } ?? []) : results
    }
    private var expandable: Bool {
        effectiveResults.contains { ($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }
    }

    var body: some View {
        let res = effectiveResults
        let lastIdx = max(res.count - 1, 0)
        let idx = pageIdx.map { min(max($0, 0), lastIdx) } ?? lastIdx
        let resultText = res.indices.contains(idx) ? res[idx] : nil
        let hasResultText = (resultText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)

        VStack(alignment: .leading, spacing: 0) {
            header(count: res.count)
            if expandable, expanded {
                Divider().background(Theme.hairline)
                VStack(alignment: .leading, spacing: 10) {
                    if hasResultText, let resultText {
                        MarkdownContent(raw: resultText)
                    } else {
                        Text("No result text.")
                            .font(.caption.italic())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if res.count > 1 {
                        pager(idx: idx, lastIdx: lastIdx, total: res.count)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
    }

    private func header(count: Int) -> some View {
        let duration = report.durationMs.map { DelegationModel.formatDuration($0) }
        let shortId = taskId.map { String($0.prefix(8)) }
        return HStack(spacing: 8) {
            Image(systemName: kind == .cancel ? "xmark.circle" : "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(badge.status == .err ? Theme.danger : Theme.textSecondary)
                .frame(width: 16)
            Text(labelKey(shortId: shortId))
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1).truncationMode(.tail)
            if count > 1 {
                Text(verbatim: "×\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
            if let duration {
                Text(verbatim: duration)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            CompanionStatusBadge(status: badge.status, errorCode: badge.errorCode)
                .fixedSize()
            if expandable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            guard expandable else { return }
            withAnimation(Theme.Motion.expand) { expanded.toggle() }
        }
    }

    private func labelKey(shortId: String?) -> LocalizedStringKey {
        switch kind {
        case .cancel:
            return shortId.map { "Canceling task #\($0)" } ?? "Canceling task"
        case .status:
            return shortId.map { "Waiting for task #\($0)’s result" } ?? "Waiting for task’s result"
        }
    }

    private func pager(idx: Int, lastIdx: Int, total: Int) -> some View {
        HStack(spacing: 12) {
            Spacer()
            Button { pageIdx = max(idx - 1, 0) } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
            }
            .disabled(idx <= 0)
            Text(verbatim: "\(idx + 1) / \(total)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Button { pageIdx = min(idx + 1, lastIdx) } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
            }
            .disabled(idx >= lastIdx)
            Spacer()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
    }
}
