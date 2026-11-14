import SwiftUI

/// The suggestion card the compose bar draws directly above its field while
/// a `/`·`$` or `@` trigger is open — so it rides the keyboard with the bar.
///
/// Rows are plain Buttons: a tap never takes focus from the field, so the
/// keyboard stays up and typing goes on filtering. The highlighted row is what
/// a hardware keyboard's Return picks (web parity: the first row by default).
struct ComposerSuggestionPanel: View {
    let state: ComposerPanelState
    let onPick: (ComposerSuggestionRow) -> Void
    let onSelectTab: (MentionTab) -> Void

    /// Tall enough for five or six rows; longer lists scroll inside it.
    private static let maxHeight: CGFloat = 240
    /// The list's own height, measured — so a short list hugs its rows.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header = mentionHeader {
                tabStrip(active: header.tab, counts: header.counts)
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    list
                        .onGeometryChange(for: CGFloat.self) { geometry in
                            geometry.size.height
                        } action: { height in
                            contentHeight = height
                        }
                }
                // Hug short lists; scroll long ones within the cap. One row's
                // worth until the first measurement lands.
                .frame(height: min(contentHeight > 0 ? contentHeight : 44, Self.maxHeight))
                .scrollDismissesKeyboard(.never)
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: state.highlighted) { _, index in
                    guard state.rows.indices.contains(index) else { return }
                    proxy.scrollTo(state.rows[index].id)
                }
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Tabs

    /// The `@` panel's tab strip state; nil for the command menu.
    private var mentionHeader: (tab: MentionTab, counts: [MentionTab: Int])? {
        switch state.content {
        case .mention(let tab, _, let counts, _, _, _, _): return (tab, counts)
        case .commands: return nil
        }
    }

    private func tabStrip(active: MentionTab, counts: [MentionTab: Int]) -> some View {
        HStack(spacing: 4) {
            ForEach(MentionTab.allCases, id: \.self) { tab in
                let isActive = tab == active
                Button { onSelectTab(tab) } label: {
                    HStack(spacing: 4) {
                        Text(tab.title)
                            .font(.caption.weight(.semibold))
                        if let count = counts[tab], count > 0 {
                            Text(verbatim: "\(count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(isActive ? Theme.accentDim : Color.clear)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(6)
    }

    // MARK: - Rows

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch state.content {
            case .commands(let rows, let loading, let skillColumn):
                if loading { statusRow("Loading commands…", spinner: true) }
                rowsView(rows, skillColumn: skillColumn)
            case .mention(_, let rows, _, let loading, _, let truncated, _):
                // An earlier query's rows (narrowed to this one) stay up while
                // this one's search runs, rather than blinking to "Searching…"
                // on every keystroke; Return waits for the fresh ones.
                if rows.isEmpty {
                    if loading {
                        statusRow("Searching…", spinner: true)
                    } else {
                        statusRow("No matches", spinner: false)
                    }
                } else {
                    rowsView(rows, skillColumn: false)
                    if truncated { statusRow("More results — keep typing to filter", spinner: false) }
                }
            }
        }
        .padding(6)
    }

    private func rowsView(_ rows: [ComposerSuggestionRow], skillColumn: Bool) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            Button { onPick(row) } label: {
                label(for: row, skillColumn: skillColumn)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .fill(index == state.highlighted ? Theme.accentDim : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(row.id)
        }
    }

    @ViewBuilder
    private func label(for row: ComposerSuggestionRow, skillColumn: Bool) -> some View {
        switch row {
        case .command(let command, let skill):
            HStack(spacing: 8) {
                if skillColumn {
                    Group {
                        if skill {
                            Image(systemName: "book.closed")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                Text(verbatim: ComposerInvocations.commandInvocationToken(command.name))
                    .font(.callout.monospaced().weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .layoutPriority(2)
                if let hint = ComposerInvocations.commandInputHint(command) {
                    Text(verbatim: hint)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Text(verbatim: command.description)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

        case .skill(let skill, let prefix):
            HStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 16, height: 16)
                Text(verbatim: skill.name.isEmpty ? skill.id : skill.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(verbatim: skill.description ?? (prefix.rawValue + skill.id))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

        case .file(let entry):
            HStack(spacing: 8) {
                Image(systemName: entry.kind == .dir ? "folder" : "doc.text")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 18, height: 18)
                Text(verbatim: entry.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(verbatim: entry.path)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)

        case .agent(let agent):
            HStack(spacing: 8) {
                AgentIcon(agent: agent.agentType)
                    .frame(width: 18, height: 18)
                Text(verbatim: agent.label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let detail = agent.detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func statusRow(_ text: LocalizedStringKey, spinner: Bool) -> some View {
        HStack(spacing: 8) {
            if spinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textTertiary)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

extension MentionTab {
    var title: LocalizedStringKey {
        switch self {
        case .agent: return "Agents"
        case .file: return "Files"
        }
    }
}
