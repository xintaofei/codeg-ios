import SwiftUI

/// The agent's plan / TODO checklist: the live one, rebuilt from `plan_update`
/// events (or a reattach snapshot), and a persisted plan-like call's
/// (`TodoWrite`, Kimi's `TodoList`, codex's `update_plan` — `PlanParse`), so a
/// plan reads the same live and in history. Display only — it never blocks the
/// turn. Drawn as one of the reply's steps, where the agent last revised it.
///
/// One row of the reply (web `PlanRow`): `Updated plan · <the step under way>
/// 3/5`, opening onto the checklist. The plan being written right now opens by
/// itself; an older update stays folded — the newest one says where things
/// stand, so a reply that revised its plan five times reads as five lines, not
/// five checklists. The user can open or close either by tapping the row.
struct LivePlanView: View {
    let entries: [PlanEntry]
    /// Whether the owning turn is still streaming (drives the in-progress spinner
    /// vs. a steady dot, and opens the row) — false for a plan in history.
    var isStreaming: Bool = true

    /// User's explicit expand/collapse, when they've tapped the row. `nil` ⇒ use
    /// the default (open while streaming). Stable because the timeline keys the
    /// plan node by the call it is recorded as (`tool-<id>`, the live plan's being
    /// the one its hand-off writes), so this state survives stream re-renders, the
    /// plan moving, the turn ending — and, kept in the screen's store, the list
    /// recycling the row.
    @DisclosureChoice("plan") private var userExpanded: Bool?

    private var completed: Int {
        entries.filter { $0.normalizedStatus == .completed }.count
    }
    /// The step under way, else the first one not done (web `current`).
    private var current: PlanEntry? {
        entries.first { $0.normalizedStatus == .inProgress }
            ?? entries.first { $0.normalizedStatus != .completed }
    }
    private var isExpanded: Bool { userExpanded ?? isStreaming }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                header
                if isExpanded {
                    PlanChecklist(items: entries.map(\.checklistItem), isStreaming: isStreaming,
                                  ink: Theme.Step.label)
                        .padding(.vertical, 2)
                        .transition(.opacity)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("Updated plan", comment: "Activity row: the agent wrote or revised its plan; followed by the step under way")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Step.label)
                    .fixedSize()
                if let current {
                    Text(verbatim: current.content)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Step.subject)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
            }
            Spacer(minLength: 6)
            Text(verbatim: "\(completed)/\(entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Theme.Motion.expand) { userExpanded = !isExpanded }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Updated plan", comment: "Activity row: the agent wrote or revised its plan; followed by the step under way"))
        .accessibilityValue(Text(verbatim: [current?.content, "\(completed)/\(entries.count)"]
            .compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(isExpanded ? Text("Collapse") : Text("Expand"))
    }
}
