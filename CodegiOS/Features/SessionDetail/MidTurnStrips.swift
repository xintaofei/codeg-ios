import SwiftUI

/// What the user wrote that has not reached the agent as a turn of its own,
/// above the composer (web `FeedbackNotesList` + `MessageQueue`, codeg 0.44):
///
/// 1. live-feedback notes sent into the running turn — waiting, or received;
///    once the turn is over, only the ones the agent never read, each with a
///    way to send it as an ordinary message instead;
/// 2. the queue — messages that go out one at a time when the agent is free.
///
/// Reads the model in its OWN body, so the parent screen isn't re-rendered by
/// what only these rows show (the notes follow the live reply's steers).
struct MidTurnStrips: View {
    let model: SessionDetailViewModel

    var body: some View {
        let notes = model.visibleFeedbackNotes
        let queued = model.queue.items
        if !notes.isEmpty || !queued.isEmpty {
            VStack(spacing: 6) {
                if !notes.isEmpty {
                    FeedbackNotesCard(
                        notes: notes,
                        turnRunning: model.feedbackTurnRunning,
                        onResend: { model.resendFeedbackNote($0) },
                        onDismiss: { model.dismissFeedbackNote($0) }
                    )
                }
                if !queued.isEmpty {
                    QueueCard(
                        items: queued,
                        held: model.queueHeld && !model.isInFlight,
                        canSteer: model.canSteer,
                        channel: model.steerChannel,
                        onSteer: { model.steerQueued($0) },
                        onEdit: { model.editQueued($0) },
                        onRemove: { model.removeQueued($0) },
                        onResume: { model.resumeQueue() }
                    )
                }
            }
            .animation(Theme.Motion.expand, value: notes)
            .animation(Theme.Motion.expand, value: model.queue.ids)
            // Inside the condition, so an empty strip takes no room at all.
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .transition(.opacity)
        }
    }
}

// MARK: - Queue

private struct QueueCard: View {
    let items: [QueuedPrompt]
    /// Paused after a send that failed — "send now" resumes it.
    let held: Bool
    let canSteer: Bool
    let channel: SteerChannel
    let onSteer: (UUID) -> Void
    let onEdit: (UUID) -> Void
    let onRemove: (UUID) -> Void
    let onResume: () -> Void

    @State private var expanded = false

    /// Rows shown before "+N more": the line is about what goes NEXT.
    private static let collapsedRows = 3

    private var shown: ArraySlice<QueuedPrompt> {
        expanded ? items[...] : items.prefix(Self.collapsedRows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: held ? "pause.circle.fill" : "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(held ? Theme.warning : Theme.textTertiary)
                Text(held ? LocalizedStringKey("Paused") : LocalizedStringKey("Queued"))
                    .font(Theme.Typography.metaLabel)
                    .foregroundStyle(Theme.textSecondary)
                Text(verbatim: "\(items.count)")
                    .font(Theme.Typography.metaLabel.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 4)
                if held {
                    Button(action: onResume) {
                        Text("Send now")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
            }
            ForEach(shown) { item in
                QueueRow(item: item,
                         canSteer: canSteer && item.attachments.isEmpty,
                         channel: channel,
                         onSteer: { onSteer(item.id) },
                         onEdit: { onEdit(item.id) },
                         onRemove: { onRemove(item.id) })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !expanded, items.count > Self.collapsedRows {
                Button {
                    withAnimation(Theme.Motion.expand) { expanded = true }
                } label: {
                    Text("+\(items.count - Self.collapsedRows) more")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: held ? Theme.warning.opacity(0.45) : Theme.surfaceStroke)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

private struct QueueRow: View {
    let item: QueuedPrompt
    let canSteer: Bool
    let channel: SteerChannel
    let onSteer: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(item.text.isEmpty ? String(localized: "Image") : item.text)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !item.attachments.isEmpty {
                Label {
                    Text(verbatim: "\(item.attachments.count)")
                } icon: {
                    Image(systemName: "photo")
                }
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
            }
            Menu {
                if canSteer {
                    Button(action: onSteer) {
                        Label(channel == .pull ? LocalizedStringKey("Send as note for next check") : LocalizedStringKey("Insert into current turn"),
                              systemImage: channel == .pull ? "clock" : "bolt.fill")
                    }
                }
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Queued message actions")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Feedback notes

private struct FeedbackNotesCard: View {
    let notes: [FeedbackItem]
    let turnRunning: Bool
    let onResend: (String) -> Void
    let onDismiss: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !turnRunning {
                // Expired: the turn these were written for is over.
                Text("The agent finished before reading your feedback.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(notes) { note in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: note.isDelivered ? "checkmark.circle.fill" : "clock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(note.isDelivered ? Theme.accent : Theme.textTertiary)
                    Text(note.text)
                        .font(.caption)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(turnRunning ? 2 : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if turnRunning {
                        Text(note.isDelivered ? LocalizedStringKey("received") : LocalizedStringKey("waiting"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize()
                    } else {
                        Button { onResend(note.id) } label: {
                            Text("Send as message")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .fixedSize()
                        Button { onDismiss(note.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.surfaceStroke)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
