import SwiftUI

/// What the dock above the composer says about THIS session — only what is in
/// progress right now (web `ComposerStatusStrips` + `SessionFailureBanner`,
/// codeg 0.44):
///
/// 1. the retry line — the cause, HTTP status, attempt N of M and the delay;
/// 2. the AIR retry incident (one strip, plus a count of the others behind it)
///    and, once it settles on its own, a short-lived "recovered" line.
///
/// Everything that is NEWS rather than progress (a failed turn, an advisory)
/// is told elsewhere — the failure line in the transcript, the notice line —
/// and never also drawn here.
struct SessionStatusStrips: View {
    let retry: TurnRetryState?
    let dock: SessionFailures.DockView
    let onDismiss: ([String]) -> Void

    /// How long the "recovered" confirmation stays before closing itself:
    /// records are kept forever as revision watermarks, so nothing else would.
    static let recoveredVisible: Duration = .seconds(10)

    var body: some View {
        VStack(spacing: 6) {
            if let incident = dock.incident?.incident, let view = dock.incident {
                IncidentStrip(record: incident, hiddenCount: view.hiddenCount) {
                    onDismiss(view.ids)
                }
                .id(incident.id)
            }
            if let recovered = dock.recovered {
                DockStrip(tone: .muted, icon: .symbol("checkmark.circle.fill"),
                          title: String(localized: "Recovered") + " · " + recovered.displayTitle,
                          onDismiss: { onDismiss([recovered.id]) })
                    .task(id: "\(recovered.id)@\(recovered.revision)") {
                        try? await Task.sleep(for: Self.recoveredVisible)
                        guard !Task.isCancelled else { return }
                        onDismiss([recovered.id])
                    }
            }
            if let retry {
                // Amber, not red: the agent is retrying on its own.
                DockStrip(tone: .warning, icon: .spinner, title: retry.lineText, onDismiss: nil)
            }
        }
        .animation(Theme.Motion.expand, value: retry)
        .animation(Theme.Motion.expand, value: dock)
    }
}

private struct IncidentStrip: View {
    let record: SessionFailureRecord
    let hiddenCount: Int
    let onDismiss: () -> Void

    var body: some View {
        DockStrip(tone: .warning, icon: .spinner, title: record.displayTitle,
                  meta: hiddenCount > 0 ? String(localized: "+\(hiddenCount) more") : nil,
                  details: details, onDismiss: onDismiss)
    }

    /// The rest of a multi-line title, then the record's details.
    private var details: String? {
        SessionNotices.splitHeadline(record.title, more: record.details)?.description
            ?? record.details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

/// One strip of the dock (web `ComposerDockStrip`): an icon, a one-line title,
/// optional details behind a tap, and a close button.
private struct DockStrip: View {
    enum Tone { case warning, muted }
    enum Icon { case spinner, symbol(String) }

    let tone: Tone
    let icon: Icon
    let title: String
    var meta: String? = nil
    var details: String? = nil
    let onDismiss: (() -> Void)?

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                iconView
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(tone == .warning ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let meta {
                    Text(meta)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                }
                if details != nil {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                if let onDismiss {
                    Button(action: onDismiss) {
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
            if expanded, let details {
                Text(details)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard details != nil else { return }
            withAnimation(Theme.Motion.expand) { expanded.toggle() }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: tone == .warning ? Theme.warning.opacity(0.45) : Theme.surfaceStroke)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case .spinner:
            ProgressView()
                .controlSize(.mini)
                .tint(Theme.warning)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone == .warning ? Theme.warning : Theme.textTertiary)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
