import SwiftUI

/// The visual shape one plan row renders from — the shared model every "Agent
/// Plan" surface maps its entries into, so the live checklist (`LivePlanView`)
/// and the ExitPlanMode confirmation (`PermissionRequestCard`) keep one shape
/// (only the open rows' ink differs; see `PlanChecklist.ink`). Mirrors codeg
/// web's shared `PlanEntriesList`.
struct PlanChecklistItem {
    let content: String
    let status: PlanEntry.Status
    /// `nil` hides the priority badge — the permission card's entries carry no
    /// priority, so only the live plan ever surfaces one.
    var priority: PlanEntry.Priority? = nil
}

extension PlanEntry {
    /// Live `plan_update` / snapshot entry → checklist row (status + priority).
    var checklistItem: PlanChecklistItem {
        PlanChecklistItem(content: content, status: normalizedStatus, priority: normalizedPriority)
    }
}

extension PermissionPlanEntry {
    /// A permission-request plan entry → checklist row. Its freeform `status`
    /// string is normalized through the same table; it never carries a priority.
    var checklistItem: PlanChecklistItem {
        PlanChecklistItem(content: text, status: PlanEntry.status(from: status), priority: nil)
    }
}

/// A plan / TODO checklist body: one status-marked row per entry, completed rows
/// struck through and dimmed. `isStreaming` swaps the in-progress marker for a
/// live spinner (so a finalized/persisted plan shows a steady dot instead).
///
/// Body only — callers wrap it in their own header / container (the live card's
/// collapsible shell, the confirmation card's "Plan" section), exactly as the web
/// shares `PlanEntriesList` between `<PlanCard>` and `<AgentPlanOverlay>`.
/// `ink` is the open rows' text: the live plan is one of a reply's steps and
/// reads in their quieter ink; the confirmation card asks the user to decide,
/// in the primary one.
struct PlanChecklist: View {
    let items: [PlanChecklistItem]
    var isStreaming: Bool = false
    var ink: Color = Theme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                PlanChecklistRow(item: item, isStreaming: isStreaming, ink: ink)
            }
        }
    }
}

private struct PlanChecklistRow: View {
    let item: PlanChecklistItem
    let isStreaming: Bool
    let ink: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            PlanStatusIcon(status: item.status, isStreaming: isStreaming)
                .frame(width: 16, height: 16)
                .padding(.top, 1.5)
            Text(item.content)
                .font(.subheadline)
                .foregroundStyle(item.status == .completed ? Theme.textTertiary : ink)
                .strikethrough(item.status == .completed, color: Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.priority == .high {
                Text("High")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.danger.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

/// The per-row status marker, shared so every plan surface agrees on iconography:
/// a green check (done), a spinner or accent dot (in progress — spinner only while
/// the turn is still streaming), or a hollow circle (pending). Always laid out in
/// a fixed 16×16 box so swapping the spinner for a glyph never reflows the row.
struct PlanStatusIcon: View {
    let status: PlanEntry.Status
    var isStreaming: Bool = false

    var body: some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(DiffPalette.addText)
        case .inProgress:
            if isStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.accent)
            } else {
                Image(systemName: "circle.inset.filled")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
            }
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
