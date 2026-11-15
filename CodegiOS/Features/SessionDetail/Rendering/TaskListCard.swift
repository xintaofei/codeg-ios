import SwiftUI

// The card for a `.taskGroup` timeline node: a run of consecutive
// `TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet` calls rendered as one
// evolving to-do checklist (Codex-mobile style). Pure parsing / flattening lives
// in `TaskOp.swift`; this is presentation only. Mirrors the shape of
// `DelegationStatusGroupCard` (a flat surface holding status-marked rows).

struct TaskListCard: View {
    let ops: [ToolCallVM]

    /// Show at most this many rows before a "Show N more" toggle (a long
    /// `TaskList` can carry dozens).
    private let collapsedLimit = 10
    /// Show more, kept across the list recycling the row.
    @DisclosureChoice("tasks.more") private var choice: Bool?
    private var expanded: Bool { choice ?? false }

    /// Every parsed op — drives the header's action summary.
    private var parsedAll: [TaskOp] {
        ops.compactMap { TaskOpParse.parse(name: $0.rawName, input: $0.input, output: $0.output) }
    }
    /// Ops that contribute checklist rows. A still-running `TaskGet`/`TaskList`
    /// hasn't produced its task data yet (its content comes from the output), so it
    /// would otherwise render a guessed "pending" row or an empty "Task list (0)" —
    /// suppress those until output arrives. A running create/update keeps its
    /// input-derived row (subject / status are already known).
    private var rowOps: [TaskOp] {
        ops.compactMap { vm in
            guard let op = TaskOpParse.parse(name: vm.rawName, input: vm.input, output: vm.output) else { return nil }
            let running = vm.state == .running || vm.state == .inputStreaming
            if running, op.kind == .get || op.kind == .list,
               op.subject == nil, op.status == nil, op.listRows.isEmpty {
                return nil
            }
            return op
        }
    }
    private var rows: [TaskChecklistRow] { TaskListBuild.rows(from: rowOps) }
    private var isRunning: Bool { ops.contains { $0.state == .running || $0.state == .inputStreaming } }

    var body: some View {
        let allRows = rows
        let isLong = allRows.count > collapsedLimit
        let shown = (isLong && !expanded) ? Array(allRows.prefix(collapsedLimit)) : allRows

        VStack(alignment: .leading, spacing: 9) {
            header(rowCount: allRows.count)
            if allRows.isEmpty {
                // Don't assert "No tasks" while a list/get is still loading — the
                // header shows "Updating tasks…" + the live pulse instead.
                if !isRunning {
                    Text("No tasks")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { TaskRow(row: $0) }
                }
                if isLong { expandToggle(hidden: allRows.count - collapsedLimit) }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
    }

    // The gutter marker carries the checklist icon + state tint; the header shows
    // just the summary and a live pulse while streaming. Errored task ops never
    // reach this card — `groupConsecutiveTaskOps` leaves them standalone so their
    // failure renders through `ToolCallCard`'s error path — so the checklist only
    // ever reflects calls that succeeded.
    private func header(rowCount: Int) -> some View {
        HStack(spacing: 8) {
            summaryLabel(rowCount: rowCount)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Step.label)
                .lineLimit(1)
                .truncationMode(.tail)
            if isRunning { LivePulse() }
            Spacer(minLength: 4)
        }
    }

    /// While a list/get is still loading (running with no rows yet), show a neutral
    /// "Updating tasks…" rather than a misleading "Task list (0)". The count comes
    /// from the deduped rows, so two updates to one task read "Updated 1 task".
    private func summaryLabel(rowCount: Int) -> Text {
        if isRunning && rowCount == 0 { return Text("Updating tasks…") }
        return TaskSummary.text(TaskListBuild.action(of: parsedAll), count: rowCount)
    }

    private func expandToggle(hidden: Int) -> some View {
        Button {
            withAnimation(Theme.Motion.expand) { choice = !expanded }
        } label: {
            (expanded ? Text("Show less") : Text("Show \(hidden) more"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

private struct TaskRow: View {
    let row: TaskChecklistRow

    private var struck: Bool { row.status == .completed || row.status == .deleted }
    private var titleColor: Color { struck ? Theme.Step.meta : Theme.Step.label }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            TaskStatusIcon(status: row.status)
                .frame(width: 16, height: 16)
                .padding(.top, 1.5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let id = row.displayID {
                        Text(verbatim: "#\(id)")
                            .font(.mono(10.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text(row.title)
                        .font(.subheadline)
                        .foregroundStyle(titleColor)
                        .strikethrough(struck, color: Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let desc = row.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Status icon

/// Per-row task status marker. Visually matches `PlanStatusIcon` for the shared
/// states (so the checklist reads the same as a plan), adding a dim ✗ for a
/// deleted task and a warning glyph for a blocked one. Always laid out in a fixed
/// box so the glyph never reflows the row.
struct TaskStatusIcon: View {
    let status: TaskItemStatus

    var body: some View {
        switch status {
        case .completed:
            icon("checkmark.circle.fill", DiffPalette.addText)
        case .inProgress:
            icon("circle.inset.filled", Theme.accent)
        case .pending:
            icon("circle", Theme.textTertiary)
        case .blocked:
            icon("exclamationmark.circle", Theme.warning)
        case .deleted:
            icon("xmark.circle.fill", Theme.textTertiary)
        }
    }

    private func icon(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .foregroundStyle(tint)
    }
}

// MARK: - Summary

/// The card's header summary for a group action, as a localized `Text`. Each
/// `Text("Added \(n) tasks")` is a `LocalizedStringKey` interpolation, so SwiftUI
/// extracts a `%lld` format and the String Catalog supplies the per-locale plural
/// (mirrors the app's `"%lld files changed"` entry).
enum TaskSummary {
    static func text(_ action: TaskGroupAction, count: Int) -> Text {
        switch action {
        case .added:   return Text("Added \(count) tasks")
        case .updated: return Text("Updated \(count) tasks")
        case .deleted: return Text("Deleted \(count) tasks")
        case .listed:  return Text("Task list (\(count))")
        case .detail:  return Text("Task details")
        case .mixed:   return Text("Tasks")
        }
    }
}
