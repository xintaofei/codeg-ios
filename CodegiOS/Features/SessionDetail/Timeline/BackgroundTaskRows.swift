import SwiftUI

/// One background task of a reply (web `BackgroundTaskRows` /
/// `BackgroundTaskRowView`, codeg 0.44): its polls folded together, the latest
/// speaking for it —
///
///     Task finished  #beecec7d  Regenerate audit report · report.md written   done ›
///
/// named after the command that started it when that is in the same reply,
/// and opening onto the task's output. A failure opens by itself.
struct BackgroundTaskRowView: View {
    let row: BackgroundTask.Row
    let launch: BackgroundLaunch?

    /// The reader's toggle, kept across the list recycling the row.
    @DisclosureChoice("task") private var userExpanded: Bool?

    private var status: StepStatus { BackgroundTask.rowStatus(row) }
    private var failed: Bool { row.badge == .failed }
    private var output: String? {
        guard let text = BackgroundTask.displayOutput(row),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
    private var expanded: Bool { userExpanded ?? failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded, let text = output {
                detail(text)
                    .transition(.opacity)
            }
        }
    }

    private var label: String {
        switch row.badge {
        case .completed:
            return String(localized: "Task finished", comment: "Background task row: the task completed")
        case .failed:
            return String(localized: "Task failed", comment: "Background task row: the task failed")
        case .stopped:
            return String(localized: "Task stopped", comment: "Background task row: the task was stopped")
        case .running:
            return String(localized: "Task running", comment: "Background task row: the task is still running")
        }
    }

    private var header: some View {
        // Label, id and detail in one ink (web parity): the row is about the
        // task, and none of its parts outranks the others.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Step.label)
                    .fixedSize()
                if let shortId = BackgroundTask.shortId(row) {
                    Text(verbatim: "#\(shortId)")
                        .font(.mono(13))
                        .foregroundStyle(Theme.Step.label)
                        .fixedSize()
                }
                if row.pollCount > 1 {
                    // How often it was polled — the delegation-poll row's hint.
                    Text(verbatim: "×\(row.pollCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.Step.meta)
                        .fixedSize()
                }
                if let detail = BackgroundTask.rowDetail(row, launch: launch) {
                    Text(verbatim: detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Step.label)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            trailing
            if output != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard output != nil else { return }
            withAnimation(Theme.Motion.expand) { userExpanded = !expanded }
        }
    }

    /// The figure on the right: how the task stands.
    @ViewBuilder
    private var trailing: some View {
        switch row.badge {
        case .failed:
            figure(row.exitCode.map { String(localized: "exit \($0)", comment: "Activity row: exit code") }
                       ?? String(localized: "failed"),
                   Theme.danger)
        case .stopped:
            figure(String(localized: "stopped", comment: "Background task row: the task was stopped"),
                   Theme.textTertiary)
        case .running:
            // Only a poll still in flight is live work; a settled "still
            // running" answer is a snapshot.
            if status == .running {
                ProgressView().controlSize(.mini)
            } else {
                figure(String(localized: "running", comment: "Background task row: the task was still running when last polled"),
                       Theme.textTertiary)
            }
        case .completed:
            figure(String(localized: "done", comment: "Background task row: the task completed"),
                   Theme.textTertiary)
        }
    }

    private func figure(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    /// A sub-agent's report is prose; a shell's output is a terminal stream.
    @ViewBuilder
    private func detail(_ output: String) -> some View {
        if row.isSubagent {
            MarkdownContent(raw: output)
        } else {
            CodeBlockView(code: output, language: "console")
        }
    }
}
