import SwiftUI

/// The agent's plan / TODO checklist: the live one, rebuilt from `plan_update`
/// events (or a reattach snapshot), and a persisted plan-like call's
/// (`TodoWrite`, Kimi's `TodoList`, codex's `update_plan` — `PlanParse`), so a
/// plan reads the same live and in history. Display only — it never blocks the
/// turn. Drawn as one of the reply's steps, where the agent last revised it.
///
/// A collapsible card (web's `AgentPlanOverlay` shape, kept inline + native): the
/// header is always visible with a completed/total count, and the checklist body
/// expands by default while work is outstanding and collapses once every entry is
/// done — the user can override either way by tapping the header.
struct LivePlanView: View {
    let entries: [PlanEntry]
    /// Whether the owning turn is still streaming (drives the in-progress spinner
    /// vs. a steady dot) — false for a plan in history.
    var isStreaming: Bool = true

    /// User's explicit expand/collapse, when they've tapped the header. `nil` ⇒ use
    /// the default (expanded while incomplete). Stable because the timeline keys the
    /// plan node by the call it is recorded as (`tool-<id>`, the live plan's being
    /// the one its hand-off writes), so this state survives stream re-renders, the
    /// plan moving, and the turn ending.
    @State private var userExpanded: Bool?

    private var completed: Int {
        entries.filter { $0.normalizedStatus == .completed }.count
    }
    private var allCompleted: Bool { !entries.isEmpty && completed == entries.count }
    private var isExpanded: Bool { userExpanded ?? !allCompleted }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.Motion.expand) { userExpanded = !isExpanded }
            } label: {
                header
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().overlay(Theme.hairline)
                PlanChecklist(items: entries.map(\.checklistItem), isStreaming: isStreaming)
                    .padding(.vertical, 5)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
    }

    private var header: some View {
        // The timeline gutter already marks this node with the checklist icon, so
        // the card header leads straight with the "Plan" label.
        HStack(spacing: 8) {
            Text("Plan")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Text(verbatim: "\(completed)/\(entries.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.surfaceNested, in: Capsule())
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plan")
        .accessibilityValue(Text(verbatim: "\(completed)/\(entries.count)"))
        .accessibilityHint(isExpanded ? "Collapse" : "Expand")
    }
}
