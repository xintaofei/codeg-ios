import SwiftUI

// A Codex `/goal` on the activity timeline (codeg 0.44 web parity:
// `goal-tool-call.tsx` and the `goal` branches of `activity-timeline.tsx` /
// `step-visuals.tsx`).

/// The goal row's gutter marker. Kept off the view: the node's marker is read
/// outside the main actor.
enum GoalRowStyle {
    static let icon = "target"

    /// Working while the run is, else settled. (The web rings a run only as
    /// running or done and tints its header red on a failure; here the marker
    /// says failed too, as it does for a lone goal call.)
    static func markerState(_ goal: ActivityGoalStep) -> ToolCallState {
        if goal.run.isRunning { return .running }
        return goal.isError ? .error : .done
    }
}

/// What a goal row can do about the session's goal (web `GoalControlValue`).
/// Set by the session screen; `none` anywhere else (a sub-agent's viewer).
struct GoalControl {
    /// Nil without a live connection to send it on. Takes the action and the
    /// goal it was asked of.
    var onControl: ((_ action: String, _ goalID: String) -> Void)?
    /// The actions the adapter offers; empty while not known.
    var actions: [String]
    /// The thread's latest goal (its opening call's id). Only it offers the
    /// controls: they act on the session's goal as it stands NOW, so an
    /// earlier goal's row would pause or clear a different one.
    var currentGoalID: String?
    /// A control sent on this goal and not yet answered: no second one until
    /// its new state lands (or it was refused).
    var pendingGoalID: String?

    static let none = GoalControl(onControl: nil, actions: [], currentGoalID: nil)

    /// Which controls a goal row with `goalID` standing at `status` offers:
    /// pause while active, clear while active or paused (resuming is issuing
    /// the `/goal` again).
    func offers(goalID: String, status: ActivityGoal.Status?) -> (pause: Bool, clear: Bool) {
        guard onControl != nil, goalID == currentGoalID, goalID != pendingGoalID else { return (false, false) }
        let active: Bool
        let paused: Bool
        switch status {
        case .active?: (active, paused) = (true, false)
        case .paused?: (active, paused) = (false, true)
        default: (active, paused) = (false, false)
        }
        return (actions.contains("pause") && active, actions.contains("clear") && (active || paused))
    }
}

private struct GoalControlKey: EnvironmentKey {
    static let defaultValue = GoalControl.none
}

extension EnvironmentValues {
    var goalControl: GoalControl {
        get { self[GoalControlKey.self] }
        set { self[GoalControlKey.self] = newValue }
    }
}

/// The goal row's words.
enum GoalRowText {
    static func status(_ status: ActivityGoal.Status) -> String {
        switch status {
        case .active:
            return String(localized: "goal.status.active", defaultValue: "active", comment: "Goal row: the goal's status")
        case .paused:
            return String(localized: "goal.status.paused", defaultValue: "paused", comment: "Goal row: the goal's status")
        case .blocked:
            return String(localized: "goal.status.blocked", defaultValue: "blocked", comment: "Goal row: the goal's status")
        case .usageLimited:
            return String(localized: "goal.status.usageLimited", defaultValue: "usage limited", comment: "Goal row: the goal's status")
        case .budgetLimited:
            return String(localized: "goal.status.budgetLimited", defaultValue: "budget limited", comment: "Goal row: the goal's status")
        case .limited:
            return String(localized: "goal.status.limited", defaultValue: "limit reached", comment: "Goal row: the goal's status")
        case .complete:
            return String(localized: "goal.status.complete", defaultValue: "complete", comment: "Goal row: the goal's status")
        case .other(let raw):
            return raw
        }
    }

    /// `5.2K tokens`.
    static func tokens(_ count: Double) -> String {
        String(localized: "\(ActivityGoal.compactTokens(count)) tokens", comment: "Goal row: a token count, e.g. “5.2K tokens”")
    }

    /// `Status: active` — a fact in the opened row.
    static func labelled(_ label: String, _ value: String) -> String {
        "\(label): \(value)"
    }
}

/// One goal (web `GoalCard`): a line — `Goal  Tidy the README  5.2K tokens ·
/// 19s   complete ›` — that opens onto the objective, the goal's budget, and
/// the run's own steps, drawn as a timeline of their own.
///
/// Whether it is open is DERIVED until the reader taps it: a live run opens
/// as soon as it holds anything (its steps arrive after its header does), it
/// folds again once it settles (the answer has been lifted out of it by
/// then), and a failed goal opens to say why.
struct GoalRunRow: View {
    let goal: ActivityGoalStep
    let agent: AgentType

    /// The reader's toggle, kept across the list recycling the row.
    @DisclosureChoice("goal") private var userOpen: Bool?
    @Environment(\.goalControl) private var control

    private var run: GoalRunPart { goal.run }
    private var facts: ActivityGoal.Facts { goal.facts }
    private var status: ActivityGoal.Status? { ActivityGoal.Status.of(facts.status) }
    private var errorText: String? {
        goal.isError ? ActivityGoal.errorText(start: run.start, end: run.end) : nil
    }

    private var autoOpens: Bool { goal.isError || (run.isRunning && !run.items.isEmpty) }
    private var hasDetails: Bool {
        facts.objective != nil || !facts.isEmptyMeta(status: status) || errorText != nil
            || !goal.model.items.isEmpty
    }
    private var open: Bool { hasDetails && (userOpen ?? autoOpens) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if open {
                details
                    .transition(.opacity)
            }
        }
        // The marker belongs to the header line. The run's own rows below
        // publish marker lines of their own, which must not move it.
        .railHead(.firstLine)
    }

    // MARK: Header

    private var tint: Color { goal.isError ? Theme.danger : Theme.Step.label }

    /// `5.2K tokens · 19s`.
    private var usage: String? {
        let pieces = [facts.tokensUsed.map(GoalRowText.tokens),
                      facts.timeUsedSeconds.map { ActivityGoal.duration(seconds: $0) }].compactMap { $0 }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    private var header: some View {
        Button {
            guard hasDetails else { return }
            withAnimation(Theme.Motion.expand) { userOpen = !open }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Goal", comment: "Goal row: a Codex /goal, before its objective")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(tint)
                        .fixedSize()
                    if let objective = facts.objective {
                        Text(verbatim: objective)
                            .font(.subheadline)
                            .foregroundStyle(goal.isError ? Theme.danger : Theme.Step.subject)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    if let usage = usage {
                        Text(verbatim: usage)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                figure
                if hasDetails {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(hasDetails ? (open ? Text("Expanded") : Text("Collapsed")) : Text(""))
    }

    /// The right-hand column: working, failed, or where the goal stands.
    @ViewBuilder
    private var figure: some View {
        if run.isRunning {
            ProgressView().controlSize(.mini)
        } else if goal.isError {
            figureText(String(localized: "failed"), Theme.danger)
        } else if let status = status {
            figureText(GoalRowText.status(status), status.tone == .error ? Theme.danger : Theme.textTertiary)
        }
    }

    private func figureText(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    // MARK: Details

    /// `Status: active · Budget: 50K tokens · Remaining: 12K tokens · Elapsed: 4.5m`.
    private var meta: String? {
        var pieces: [String] = []
        if let status = status {
            pieces.append(GoalRowText.labelled(String(localized: "Status"), GoalRowText.status(status)))
        }
        if let used = facts.tokensUsed {
            pieces.append(GoalRowText.labelled(
                String(localized: "Tokens used", comment: "Goal row: tokens the goal has used so far"),
                GoalRowText.tokens(used)))
        }
        if let budget = facts.tokenBudget {
            pieces.append(GoalRowText.labelled(
                String(localized: "Budget", comment: "Goal row: the goal's token budget"),
                GoalRowText.tokens(budget)))
        }
        if let remaining = facts.remainingTokens {
            pieces.append(GoalRowText.labelled(
                String(localized: "Remaining", comment: "Goal row: tokens left in the goal's budget"),
                GoalRowText.tokens(remaining)))
        }
        if let seconds = facts.timeUsedSeconds {
            pieces.append(GoalRowText.labelled(
                String(localized: "Elapsed", comment: "Goal row: how long the goal has run"),
                ActivityGoal.duration(seconds: seconds)))
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let objective = facts.objective {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Objective", comment: "Goal row: the label above the goal's objective")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                    Text(verbatim: objective)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Step.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if let meta = meta {
                Text(verbatim: meta)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controls
            if let errorText = errorText {
                Text(verbatim: errorText)
                    .font(Theme.Typography.diffCode)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(16)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.danger.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            if !goal.model.items.isEmpty {
                steps
            }
        }
    }

    /// Pause and Clear, on the thread's current goal while it can take them.
    @ViewBuilder
    private var controls: some View {
        let offers = control.offers(goalID: run.start.id, status: status)
        if offers.pause || offers.clear {
            HStack(spacing: 8) {
                if offers.pause {
                    Button { control.onControl?("pause", run.start.id) } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                }
                if offers.clear {
                    Button { control.onControl?("clear", run.start.id) } label: {
                        Label("Clear", systemImage: "xmark")
                    }
                }
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Theme.textSecondary)
        }
    }

    /// The run's own steps, on a rail of their own — the same rows a reply
    /// draws. A settled run ends them on the control that folds the row.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(TranscriptTimeline.goalBodyNodes(goal, agent: agent)) { node in
                TimelineRailRow(marker: node.marker, connectTop: node.connectTop,
                                connectBottom: node.connectBottom) {
                    NodeBody(node: node)
                }
            }
            if !run.isRunning {
                foot
            }
        }
    }

    /// `Collapse · 3 steps`.
    private var foot: some View {
        Button {
            withAnimation(Theme.Motion.expand) { userOpen = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                Text("Collapse")
                if goal.model.summary.steps > 0 {
                    Text(verbatim: "· " + String(localized: "\(goal.model.summary.steps) steps", comment: "Activity header: number of steps"))
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

private extension ActivityGoal.Facts {
    /// Nothing for the opened row's facts line.
    func isEmptyMeta(status: ActivityGoal.Status?) -> Bool {
        status == nil && tokensUsed == nil && tokenBudget == nil && remainingTokens == nil
            && timeUsedSeconds == nil
    }
}
