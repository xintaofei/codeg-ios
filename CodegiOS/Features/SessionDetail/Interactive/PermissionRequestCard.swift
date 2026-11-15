import SwiftUI

/// The inline approval card for a `permission_request` — and for ExitPlanMode,
/// whose proposed plan renders in the body. Pinned above the compose bar while
/// the agent is blocked. Mirrors codeg web's `permission-dialog.tsx`: a header,
/// a contextual body (command / diff / plan / allowed actions / web / raw), and
/// the agent-supplied option buttons (filled to allow, bordered to reject — the
/// other way round on a `defaultToNo` ask).
struct PermissionRequestCard: View {
    let pending: PendingPermission
    /// Resolve with the chosen `option_id`. Returns true on success — the model
    /// then clears the card; false keeps it and re-enables the buttons.
    let onRespond: (String) async -> Bool

    @State private var submittingOptionId: String?
    @State private var failed = false

    private var parsed: ParsedPermission { pending.parsed }

    /// What each option would actually grant, for the options that say. Empty for
    /// every agent that ships no `_meta.permission` (i.e. everything but codex
    /// ≥1.1.8 and claude ≥0.64.1).
    private var optionGrants: [(option: PermissionOption, changes: [PermissionOptionChange])] {
        pending.options.compactMap { option in
            let changes = option.changes
            return changes.isEmpty ? nil : (option, changes)
        }
    }

    /// Long bodies (diffs, plan prose, many entries) get a height-capped scroll;
    /// short ones render inline so the card stays compact.
    ///
    /// ANY grant list forces the scroll: this card lives in a bottom safe-area
    /// inset, and its option buttons must stay reachable no matter what the agent
    /// wrote. The descriptions are agent-authored, so their rendered height is not
    /// something this layout gets to assume.
    private var bodyScrolls: Bool {
        !parsed.diffFiles.isEmpty || parsed.planMarkdown != nil
            || parsed.planEntries.count > 4 || parsed.allowedPrompts.count > 4
            || !optionGrants.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if bodyScrolls {
                // Scrolls only when the body does not fit under the cap; a
                // short one keeps its own height instead of a blank band
                // around it (a scroll view, like `.frame(maxHeight:)`, takes
                // all the height it is offered).
                HeightCap(limit: 300) {
                    ViewThatFits(in: .vertical) {
                        bodyContent
                        ScrollView { bodyContent }
                    }
                }
            } else {
                bodyContent
            }

            if failed {
                Label("Couldn’t submit. Please try again.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }

            VStack(spacing: 8) {
                ForEach(pending.options) { option in
                    optionButton(option)
                }
            }
        }
        .padding(14)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg)
        .shadow(color: .black.opacity(0.14), radius: 12, y: 3)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: parsed.isPlan ? "list.bullet.clipboard" : "exclamationmark.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                heading
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                subtitle
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // Only one card shows at a time, so without this the remaining
            // approvals look like the agent has stopped responding.
            if pending.queued > 0 {
                Text("+\(pending.queued) waiting")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.warning.opacity(0.16), in: Capsule())
                    .lineLimit(1)
                    .fixedSize()
            }
            if parsed.networkHost != nil {
                kindBadge(Text("network"))
            } else if !parsed.isPlan, !parsed.kind.isEmpty {
                kindBadge(Text(verbatim: parsed.kind))
            }
        }
    }

    /// A sandbox network request gets the CLI's own framing; anything else
    /// prefers the agent's human-readable description over the raw title — for
    /// a shell request the title IS the command, which the body already shows.
    private var heading: Text {
        if parsed.networkHost != nil { return Text("Network request outside the sandbox") }
        return Text(verbatim: parsed.description ?? parsed.title)
    }

    /// The agent's own reason for asking, when it gave one — strictly more
    /// informative than the boilerplate it replaces, and the only place
    /// codex-acp ≥1.7.0 still carries it. Wraps: the decision rests on it.
    private var subtitle: Text {
        if let reason = parsed.reason { return Text(verbatim: reason) }
        if parsed.networkHost != nil { return Text("Allow this connection?") }
        return parsed.isPlan
            ? Text("The agent wants to proceed with this plan.")
            : Text("The agent needs permission to continue.")
    }

    private func kindBadge(_ label: Text) -> some View {
        label
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .lineLimit(1)
    }

    // MARK: Body

    @ViewBuilder
    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let host = parsed.networkHost {
                // The request is only this host — what is asked, of which host.
                HStack(spacing: 8) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text("Host")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(verbatim: host)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.layoutDirection, .leftToRight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }

            if let command = parsed.command {
                section("Command", "terminal") {
                    CodeBlockView(code: command, language: "bash")
                    if let cwd = parsed.cwd {
                        Text(verbatim: "cwd: \(cwd)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            if !parsed.diffFiles.isEmpty {
                DiffView(files: parsed.diffFiles)
            }

            if let plan = parsed.planMarkdown {
                section("Plan", "doc.text") {
                    MarkdownContent(raw: plan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                }
            } else if !parsed.planEntries.isEmpty {
                section("Plan", "checklist") {
                    // The same checklist the live plan renders — so the proposed
                    // plan the user is approving reads exactly like the plan that
                    // streams once they do (not streaming here: a steady marker).
                    PlanChecklist(items: parsed.planEntries.map(\.checklistItem))
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                }
            }

            if !parsed.allowedPrompts.isEmpty {
                section("Allowed actions", "checkmark.seal") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(parsed.allowedPrompts.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                if !item.tool.isEmpty {
                                    Text(verbatim: item.tool)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Theme.textSecondary)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                }
                                Text(verbatim: item.prompt)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if let mode = parsed.modeTarget {
                Label { Text("Target mode: \(mode)") } icon: { Image(systemName: "arrow.triangle.swap") }
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            if parsed.url != nil || parsed.query != nil || parsed.prompt != nil {
                section("Web", "globe") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let url = parsed.url {
                            Text(verbatim: url).font(.caption.monospaced()).foregroundStyle(Theme.textPrimary)
                        }
                        if let query = parsed.query {
                            Text(verbatim: query).font(.subheadline).foregroundStyle(Theme.textPrimary)
                        }
                        if let prompt = parsed.prompt {
                            Text(verbatim: prompt).font(.subheadline).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !optionGrants.isEmpty {
                section("What each option grants", "key") { grantsList }
            }

            if !parsed.hasStructuredBody {
                CodeBlockView(code: parsed.jsonPreview, language: "json")
            }
        }
    }

    /// Per-option grant lists. Only some options carry one (claude tags the
    /// always-allow option alone), so each list is named by its button.
    private var grantsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(optionGrants, id: \.option.id) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: entry.option.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(Array(entry.changes.enumerated()), id: \.offset) { _, change in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            // Duration first, so it reads as a scannable column:
                            // "Always Allow" alone never says whether the rule
                            // dies with the session or lands in settings the
                            // repo commits.
                            if let scope = change.scope { scopeBadge(scope) }
                            Text(verbatim: change.description)
                                .font(.caption)
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    }

    /// A grant that outlives the session gets the warning tint; one that expires
    /// on its own reads as neutral chrome.
    private func scopeBadge(_ scope: PermissionChangeScope) -> some View {
        Text(scope.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(scope.isPersistent ? Theme.warning : Theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (scope.isPersistent ? Theme.warning.opacity(0.14) : Color.primary.opacity(0.06)),
                in: Capsule()
            )
            .lineLimit(1)
            .fixedSize()
    }

    private func section<Content: View>(_ label: LocalizedStringKey, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    // MARK: Option buttons

    /// The option that gets the single filled (accent) button: the approve on an
    /// ordinary ask, the decline on a `defaultToNo` one (claude-agent-acp
    /// ≥0.77.0 — "must not be approvable by a stray keystroke"). Nothing is
    /// pre-selected either way; every option stays one tap away.
    private func isEmphasized(_ option: PermissionOption) -> Bool {
        parsed.defaultToNo ? option.isReject : !option.isReject
    }

    private func optionButton(_ option: PermissionOption) -> some View {
        let emphasized = isEmphasized(option)
        return Button {
            Task { await tap(option) }
        } label: {
            HStack(spacing: 6) {
                if submittingOptionId == option.optionId {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(emphasized ? Theme.onAccent : Theme.textPrimary)
                }
                Text(verbatim: option.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(emphasized ? Theme.onAccent : Theme.textPrimary)
            .background(
                emphasized ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.06)),
                in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
            )
            .overlay {
                if !emphasized {
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(submittingOptionId != nil)
        .opacity(submittingOptionId != nil && submittingOptionId != option.optionId ? 0.5 : 1)
    }

    private func tap(_ option: PermissionOption) async {
        guard submittingOptionId == nil else { return }
        submittingOptionId = option.optionId
        failed = false
        let ok = await onRespond(option.optionId)
        // On success the model removes the card; on failure re-enable + flag.
        if !ok {
            failed = true
            submittingOptionId = nil
        }
    }
}

/// Offers its content at most `limit` points of height and takes only what the
/// content uses — unlike `.frame(maxHeight:)`, which grows to the limit
/// whenever more is on offer.
private struct HeightCap: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let offered = min(proposal.height ?? limit, limit)
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: offered))
        return CGSize(width: size.width, height: min(size.height, offered))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
