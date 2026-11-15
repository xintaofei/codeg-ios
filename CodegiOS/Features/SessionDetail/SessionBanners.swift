import SwiftUI

/// "Restart to apply" (web `SessionConfigStaleBanner`): the agent's settings
/// changed after it was spawned, so this session still runs on the old ones.
/// Reconnecting ends the agent process — never mid-turn — and resumes the same
/// session on a fresh one.
///
/// Reads ``ConnectionRunsModel`` in its own body, like the running chip, so a
/// change there re-renders this alone.
struct ConfigStaleBanner: View {
    let runs: ConnectionRunsModel
    /// A turn of this screen's is running; `runs` knows about anyone else's.
    let turnRunning: Bool
    let busy: Bool
    let onReconnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        if let stale = runs.configStale, !stale.dismissed {
            let blocked = turnRunning || runs.isPrompting
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(stale.kind == .modelProvider ? "Model provider updated" : "Agent settings updated")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("This session is still using its previous configuration. Reconnect to apply — your conversation history is kept.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Reconnecting ends the agent process, and Remote Control runs in it.
                    if runs.remoteControl != nil {
                        Text("Reconnecting also turns off Remote Control.")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button(action: onReconnect) {
                            HStack(spacing: 5) {
                                if busy {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(busy ? "Reconnecting…" : "Reconnect to apply")
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.warning)
                        .foregroundStyle(Theme.onAccent)
                        .disabled(blocked || busy)
                        if blocked, !busy {
                            Text("Available once the current turn finishes")
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 5)
                }

                Spacer(minLength: 0)

                // For this drift only: a later settings change shows it again.
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(14)
            .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.warning.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.opacity)
        }
    }
}

/// Claude Code's Remote Control is on (web `RemoteControlStrip`): this session
/// can be continued from claude.ai/code or the Claude app, and its agent keeps
/// running for it after this screen is gone. The adapter answers the command
/// itself and nothing of the exchange reaches the transcript, so a reload that
/// finds it on has only this to show the link.
///
/// A chip beside the running one — both are the state of something running
/// right now — whose menu opens or copies the link, or turns Remote Control
/// off with Claude Code's own command (which waits for a running turn).
struct RemoteControlChip: View {
    let runs: ConnectionRunsModel
    let turnRunning: Bool
    let onTurnOff: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        ZStack {
            if let info = runs.remoteControl {
                let blocked = turnRunning || runs.isPrompting
                Menu {
                    if let url = info.sessionUrl {
                        Section(url) {
                            if let openable = info.openableURL {
                                Button {
                                    openURL(openable)
                                } label: {
                                    Label("Open in browser", systemImage: "safari")
                                }
                            }
                            Button {
                                UIPasteboard.general.string = url
                                copied = true
                            } label: {
                                Label("Copy link", systemImage: "doc.on.doc")
                            }
                        }
                    } else {
                        Text("Claude Code returned no link for this session")
                    }
                    Button(role: .destructive, action: onTurnOff) {
                        Label {
                            Text("Turn off")
                            if blocked { Text("Available once Claude has finished") }
                        } icon: {
                            Image(systemName: "power")
                        }
                    }
                    .disabled(blocked)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text(copied ? "Copied" : "Remote Control is on")
                            .font(Theme.Typography.metaLabel)
                            .foregroundStyle(Theme.textSecondary)
                        if !copied, let host = info.openableURL?.host {
                            Text(verbatim: host)
                                .font(Theme.Typography.metaLabel)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.surfaceStroke, lineWidth: 0.75))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens, copies or turns off the Remote Control link"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .animation(Theme.Motion.expand, value: runs.remoteControl != nil)
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// The conversation's agent session couldn't be loaded (web
/// `acpLoadErrorBanner`), docked where the composer sits — a send would only
/// fail the same way. The transcript stays readable above it.
struct SessionLoadFailureBanner: View {
    let failure: SessionLoadFailure
    let onReload: () -> Void
    /// Nil when there is no folder to open a new conversation in.
    let onNewConversation: (() -> Void)?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                Text(verbatim: failure.message)
                    .font(.footnote)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            // One row while it fits; else the copy on a row of its own above
            // the other two; else all stacked (three actions overflow a
            // phone's width, and the longer languages overflow two).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { copyAction; recoveryActions }
                VStack(alignment: .leading, spacing: 8) {
                    copyAction
                    HStack(spacing: 8) { recoveryActions }
                }
                VStack(alignment: .leading, spacing: 8) { copyAction; recoveryActions }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(Theme.danger)
            .padding(.leading, 24)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.danger.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// The copy needs no conversation, so it is offered on its own: the id it
    /// carries is hard to retype out of the prose.
    @ViewBuilder
    private var copyAction: some View {
        if let command = failure.command {
            Button {
                UIPasteboard.general.string = command
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy command",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        Button(action: onReload) {
            Label("Reload", systemImage: "arrow.clockwise")
        }
        if let onNewConversation {
            Button(action: onNewConversation) {
                Label("New conversation", systemImage: "plus")
            }
        }
    }
}
