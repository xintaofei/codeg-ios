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

// MARK: - delegate_to_agent / resume_delegation

/// A delegation's status as a colour: quiet when done, loud when it failed or
/// waits on the user. Shared by the card's rail marker and its checks'.
enum DelegationTint {
    static func of(_ status: DelegationCardStatus) -> Color {
        switch status {
        case .starting, .running: return Theme.accent
        case .waiting: return Theme.warning
        case .ok: return DiffPalette.addText
        case .err: return Theme.danger
        }
    }
}

/// A delegation's rail marker (web `DelegationIdentityGlyph` in a `RailIcon`):
/// the logo of the agent that took the task, ringed in how it stands. A resume
/// wears a small replay mark on its ring.
struct DelegationRailGlyph: View {
    let agent: AgentType?
    let tint: Color
    let size: CGFloat
    var resumed = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let agent {
                    AgentIcon(agent: agent)
                        .frame(width: size * 0.56, height: size * 0.56)
                } else {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.6), lineWidth: 1))
            if resumed {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 12, height: 12)
                    .background(Theme.bg, in: Circle())
                    .overlay(Circle().strokeBorder(tint.opacity(0.6), lineWidth: 0.75))
                    .offset(x: 3, y: 2)
            }
        }
        .frame(width: size, height: size)
    }
}

/// One delegation, start to finish (web `DelegationRow`): `Codex  #14be49e7
/// done · 1m 34s`, the task it was handed, and — once it reports — how far it
/// got, the first line of what it came back with, and the way into its own
/// session. Opened, the whole task, where it ran, why it was resumed and the
/// full result. A `resume_delegation` draws the same card, marked resumed.
///
/// How it stands comes from the connection's live binding, then the broker's
/// stamp on the call, then the newest check on its task (``DelegationCard``).
/// With nothing to draw it by it falls back to the plain tool card — and a
/// refused resume to the card that states the refusal.
struct DelegationTaskCard: View {
    let vm: ToolCallVM
    var later: DelegationTaskRow?

    @Environment(\.activityLive) private var live
    @Environment(\.liveClocks) private var clocks
    /// The panel's toggle, kept across the list recycling the row.
    @DisclosureChoice("delegation") private var choice: Bool?
    private var expanded: Bool { choice ?? false }
    @State private var sessionOpen = false

    var body: some View {
        if let card = live.delegationCard(vm, later: later) {
            content(card)
        } else if let refusal = DelegationModel.resumeRefusal(vm) {
            RefusedResumeCard(vm: vm, refusal: refusal)
        } else {
            ToolCallCard(vm: vm)
        }
    }

    /// The call a permission request waits on: the user's to answer.
    private var awaiting: Bool {
        (vm.state == .running || vm.state == .inputStreaming) && live.awaitingToolCallId == vm.id
    }

    private func content(_ card: DelegationCard) -> some View {
        let taskLine = card.task.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .flatMap { $0.isEmpty ? nil : $0 }
        let hasDetail = card.task != nil || card.workingDir != nil || card.reason != nil || card.outcome != nil
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    titleLine(card, hasDetail: hasDetail)
                    // The task, until the panel shows it whole.
                    if !expanded, let taskLine {
                        Text(verbatim: taskLine)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard hasDetail else { return }
                    withAnimation(Theme.Motion.expand) { choice = !expanded }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(hasDetail ? .isButton : [])
                .accessibilityValue(hasDetail ? (expanded ? Text("Expanded") : Text("Collapsed")) : Text(verbatim: ""))
                // Its own element: the way into the child's session is a button.
                progressLine(card)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if expanded, hasDetail {
                Divider().overlay(Theme.hairline)
                detail(card)
                    .transition(.opacity)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
        // Waiting on the user's approval, it shows what it would hand over —
        // as it starts waiting, or when drawn while it waits unless the
        // reader already chose (a row the list recycled comes back as left).
        .onChange(of: awaiting, initial: true) { was, now in
            if now, hasDetail, was != now || choice == nil { choice = true }
        }
        .sheet(isPresented: $sessionOpen) {
            if let child = card.childConversationId {
                SubAgentSessionSheet(
                    source: .conversation(child),
                    agentType: card.agentType ?? .other(wire: ""),
                    subagentType: card.assistantName ?? card.agentType?.label,
                    task: card.task,
                    live: card.working || card.status == .waiting
                )
            }
        }
    }

    private func titleLine(_ card: DelegationCard, hasDetail: Bool) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: card.assistantName ?? card.agentType?.label ?? String(localized: "Sub-agent"))
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Step.label)
                .lineLimit(1)
            if card.assistantName != nil, let agent = card.agentType {
                Text(verbatim: "· \(agent.label)")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            if let taskId = card.taskId {
                Text(verbatim: "#" + taskId.prefix(8))
                    .font(.mono(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if card.resumed {
                Text("Resumed")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.textTertiary.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
            }
            Spacer(minLength: 4)
            statusWord(card)
                .fixedSize()
            if hasDetail {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// While it works, its own connection is the freshest source of how far
    /// it got (web `useChildProgress`); the checks' reports cover the rest,
    /// and once it is done say how it ended.
    private func progress(_ card: DelegationCard) -> DelegationProgress? {
        guard card.working || card.status == .waiting,
              let child = live.delegationBinding(for: vm)?.childConnectionId,
              let fresh = live.childProgress[child] else { return card.progress }
        return fresh
    }

    /// How the delegation stands, at the end of its line (web
    /// `DelegationStatusWord`), with how long it took once it ended — and,
    /// while it runs, a clock once it has run a while (web `useLiveElapsed`,
    /// counted from when this screen first saw it running).
    @ViewBuilder
    private func statusWord(_ card: DelegationCard) -> some View {
        if !awaiting, card.status == .running, let clocks {
            let started = clocks.start(for: vm.id)
            TimelineView(.periodic(from: started, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(started)
                (Text("Running") + Text(verbatim: elapsed >= LiveClockStore.showsAfter
                                        ? " · " + LiveClockStore.clock(elapsed) : ""))
                    .foregroundStyle(Theme.accent)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
            }
        } else {
            settledWord(card)
        }
    }

    @ViewBuilder
    private func settledWord(_ card: DelegationCard) -> some View {
        let took = card.durationMs.flatMap { $0 > 0 ? " · " + DelegationModel.formatDuration($0) : nil } ?? ""
        Group {
            if awaiting {
                Text("needs you").foregroundStyle(Theme.warning)
            } else {
                switch card.status {
                case .starting: Text("Starting").foregroundStyle(Theme.textTertiary)
                case .running: Text("Running").foregroundStyle(Theme.accent)
                case .waiting: Text("Waiting").foregroundStyle(Theme.warning)
                case .ok:
                    (Text("Done") + Text(verbatim: took)).foregroundStyle(Theme.textSecondary)
                case .err:
                    (Text(CompanionStatusBadge.errorLabel(card.errorCode)) + Text(verbatim: took))
                        .foregroundStyle(Theme.danger)
                }
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
    }

    /// The line under the title (web `ProgressLine`): its steps, what it is
    /// doing now — or, once it ended, the first line of its result — and the
    /// way into its own session.
    @ViewBuilder
    private func progressLine(_ card: DelegationCard) -> some View {
        let progress = progress(card)
        let steps = progress.flatMap { $0.steps > 0 ? $0.steps : nil }
        let summary = card.settled ? DelegationModel.previewLine(card.outcome)
            : (card.working ? progress?.lastStep : nil)
        if steps != nil || summary != nil || card.childConversationId != nil {
            HStack(spacing: 8) {
                if let steps {
                    Text("\(steps) steps")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(verbatim: summary ?? "")
                    .font(.caption)
                    .foregroundStyle(card.settled ? Theme.textSecondary : Theme.accent)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if card.childConversationId != nil {
                    Button {
                        sessionOpen = true
                    } label: {
                        HStack(spacing: 3) {
                            Text("Open session")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
        }
    }

    /// What was handed over, where, why again, and what came back.
    private func detail(_ card: DelegationCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let task = card.task {
                section("Task") {
                    // A task is often a whole brief: a screenful until asked for the rest.
                    ClampedDetail(name: "task.more") {
                        Text(verbatim: task.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.footnote)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
            }
            if let dir = card.workingDir {
                section("Working directory") {
                    Text(verbatim: dir)
                        .font(.mono(11))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
            if let reason = card.reason {
                section("Why it was resumed") {
                    // The context passed into the child's continuation, as sent: plain text.
                    ClampedDetail(name: "reason.more") {
                        Text(verbatim: reason)
                            .font(.footnote)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
            }
            if let outcome = card.outcome {
                section("Result") {
                    if card.status == .err {
                        Text(verbatim: outcome.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                            .textSelection(.enabled)
                    } else {
                        ClampedDetail(name: "result.more") { MarkdownContent(raw: outcome) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func section<Body: View>(_ title: LocalizedStringKey, @ViewBuilder _ body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
            body()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A long body held to a screenful until asked for the rest (web
/// `useCollapsibleOverflow`), with a Show more / Show less toggle once it
/// overflows.
private struct ClampedDetail<Content: View>: View {
    @ViewBuilder var content: () -> Content

    /// Show more, kept across the list recycling the row.
    @DisclosureChoice private var choice: Bool?
    private var expanded: Bool { choice ?? false }
    @State private var contentHeight: CGFloat = 0

    /// - Parameter name: what its Show more is remembered as, within the
    ///   card's row (a card holds several).
    init(name: String, @ViewBuilder content: @escaping () -> Content) {
        self.content = content
        _choice = DisclosureChoice(name)
    }

    private static var clampHeight: CGFloat { 220 }

    private var overflowing: Bool { contentHeight > Self.clampHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .frame(maxHeight: overflowing && !expanded ? Self.clampHeight : nil, alignment: .top)
                .clipped()
            if overflowing {
                Button {
                    withAnimation(Theme.Motion.expand) { choice = !expanded }
                } label: {
                    Text(expanded ? "Show less" : "Show more")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
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
                    .foregroundStyle(Theme.Step.label)
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
                        // Each task's row remembers its own toggle.
                        .disclosureScope("task-\(row.id)")
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

    /// The row's toggle, kept across the list recycling the card.
    @DisclosureChoice("row") private var choice: Bool?
    private var expanded: Bool { choice ?? false }
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
                .foregroundStyle(Theme.Step.label)
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
            withAnimation(Theme.Motion.expand) { choice = !expanded }
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
