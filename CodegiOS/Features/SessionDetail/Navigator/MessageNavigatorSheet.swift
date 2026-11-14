import SwiftUI

/// The "Messages" sheet (web `MessageNavList`): one row per user message of
/// the whole conversation, in order and opened at the latest — its number, its
/// first words, when it was sent, and what its round changed. Tapping a row
/// closes the sheet and brings the message to the top of the transcript,
/// paging older history in first when it is above what is loaded.
///
/// While the agent is answering a message, that message is listed apart above
/// the others. While the outline of the history above the loaded window loads
/// (or failed to), a row at the top says so — the messages below it are the
/// loaded ones, numbered as they are in the whole conversation.
///
/// v1 leaves out the web's inline diffs, sub-agent rows and the highlight of
/// the message the transcript is showing.
struct MessageNavigatorSheet: View {
    let model: SessionDetailViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [MessageNavEntry] = []
    @State private var built = false

    /// Everything the entries are built from, cheaply: a change re-runs the
    /// build (off the main actor), and nothing else does.
    private struct BuildKey: Equatable {
        var turnsVersion: Int
        var pendingIDs: [String]
        var earlier: NavigatorEarlier
        var outlineRevision: Int
        var window: OutlineAnchor?
        var userTurnsBefore: Int?
    }

    private var buildKey: BuildKey {
        BuildKey(
            turnsVersion: model.turnsVersion,
            pendingIDs: model.pendingUserTurns.map(\.id),
            earlier: model.navigatorEarlier,
            outlineRevision: model.outline.revision,
            window: model.navigatorWindowKey,
            userTurnsBefore: model.window?.userTurnsBefore
        )
    }

    var body: some View {
        NavigationStack {
            content
                .background(CodegBackground())
                .navigationTitle("Messages")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onAppear { model.navigatorDidAppear() }
        .onDisappear { model.navigatorDidDisappear() }
        // The window moved under the open sheet (a page, a refresh, a
        // re-anchor): the outline it needs now is a different one.
        .onChange(of: model.navigatorWindowKey) { _, _ in model.ensureOutline() }
        .task(id: buildKey) {
            let input = model.navigatorInput()
            // Every edit of a long history is parsed for its line counts —
            // real work, kept off the main actor.
            let result = await Task.detached(priority: .userInitiated) {
                MessageNavEntries.build(input)
            }.value
            guard !Task.isCancelled else { return }
            entries = result
            built = true
        }
    }

    @ViewBuilder
    private var content: some View {
        let runningID = model.navigatorRunningTurnID
        let pinned = runningID.flatMap { id in entries.last { $0.turnID == id } }
        let listed = pinned.map { running in entries.filter { $0.turnID != running.turnID } } ?? entries
        let earlier = model.navigatorEarlier

        if built, entries.isEmpty, earlier == .allLoaded {
            EmptyStateView(
                icon: "list.number",
                title: "No messages yet",
                message: "Send a message to start this session."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !built {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if let pinned {
                    // Apart from the list, so what is under way stays in view
                    // however far up the list is scrolled.
                    row(pinned, running: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    Divider().overlay(Theme.hairline)
                }
                List {
                    if earlier != .allLoaded, earlier != .ready {
                        earlierRow(earlier)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(listed) { entry in
                        row(entry, running: false)
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.hairline)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Opened at the latest message.
                .defaultScrollAnchor(.bottom)
            }
        }
    }

    @ViewBuilder
    private func earlierRow(_ earlier: NavigatorEarlier) -> some View {
        switch earlier {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading earlier messages…")
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
        case .failed:
            Button {
                model.retryOutline()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Load earlier messages")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .unsupported:
            // A server without the outline: the list starts at the loaded
            // window, and its numbers can't count what is above it.
            Text("Earlier messages aren't listed.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        case .allLoaded, .ready:
            EmptyView()
        }
    }

    private func row(_ entry: MessageNavEntry, running: Bool) -> some View {
        Button {
            model.jumpToMessage(entry)
            dismiss()
        } label: {
            MessageNavRow(entry: entry, running: running,
                          revealing: model.revealingTurnID == entry.turnID)
        }
        .buttonStyle(.plain)
    }
}

/// One message: its number in a pill, its first words over two lines, then
/// when it was sent and what its round changed.
private struct MessageNavRow: View {
    @Environment(\.locale) private var locale
    let entry: MessageNavEntry
    let running: Bool
    let revealing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(entry.ordinal)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(running ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 5)
                .frame(minWidth: 22, minHeight: 22)
                .background(running ? Theme.accent.opacity(0.15) : Color.primary.opacity(0.06), in: Capsule())

            VStack(alignment: .leading, spacing: 4) {
                label
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                meta
            }

            if revealing {
                ProgressView()
                    .controlSize(.small)
            } else if running {
                Text("Running")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var label: Text {
        if let text = entry.label { return Text(verbatim: text) }
        return Text("User message")
    }

    /// `2h ago · +12 −3 · 2 files` — a zero left out.
    private var meta: some View {
        HStack(spacing: 6) {
            Text(verbatim: RelativeTime.string(from: entry.sentAt, locale: locale))
                .foregroundStyle(Theme.textTertiary)
            if entry.additions > 0 || entry.deletions > 0 {
                HStack(spacing: 4) {
                    if entry.additions > 0 {
                        Text(verbatim: "+\(entry.additions)").foregroundStyle(DiffPalette.addText)
                    }
                    if entry.deletions > 0 {
                        Text(verbatim: "−\(entry.deletions)").foregroundStyle(DiffPalette.delText)
                    }
                }
                .font(.caption2.monospacedDigit())
                // One left-to-right unit, so a right-to-left row keeps each
                // sign in front of its number.
                .environment(\.layoutDirection, .leftToRight)
            }
            if entry.fileCount > 0 {
                Text(verbatim: "·").foregroundStyle(Theme.textTertiary)
                Text("\(entry.fileCount) files")
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.caption2)
        .lineLimit(1)
    }
}
