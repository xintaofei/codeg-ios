import SwiftUI

/// Per-conversation notice for pi's PROJECT TRUST decision.
///
/// pi loads a repo's own `.pi/*` — settings, skills, prompts, themes, system-prompt
/// overrides, and `.pi/extensions`, which are JS/TS modules whose top level runs at
/// pi startup with the user's permissions — but only once the workspace is trusted
/// in pi's `~/.pi/agent/trust.json`. Because pi-acp spawns `pi --mode rpc` (no UI),
/// pi cannot ask, and its own default is to skip those resources.
///
/// codeg used to write that trust automatically on every pi launch, which answered
/// "yes" on the user's behalf — so merely opening a conversation on a cloned repo
/// executed whatever it shipped in `.pi/extensions`. That is gone, and the decision
/// surfaces here instead, in the two shapes removing the seeding leaves behind:
/// nothing has decided (pi is skipping the resources), or a grant is already in
/// force that nobody here confirmed. Because pi runs extensions at startup, a
/// warning shown after connecting would come too late — so the backend refuses to
/// launch pi while such a grant stands, and answering here is what releases it.
///
/// Sits in the compose-bar inset alongside the interactive prompt cards, for the
/// same reason they do: the user's next action is to answer it. The bar itself is
/// deliberately terse — a repo can ship a dozen resources — with the full list and
/// the destructive choices behind "Review".
struct PiTrustNoticeView: View {
    let notice: SessionDetailViewModel.PiTrustNotice
    let state: PiProjectTrustState
    let disabled: Bool
    let busy: Bool
    let onReview: () -> Void
    let onDismiss: () -> Void

    /// Whether any gated resource executes repo-controlled code rather than
    /// merely feeding pi repo-controlled text. Worth saying plainly.
    private var executes: Bool { state.resources.contains { $0.executesCode } }

    /// A grant that came from an ancestor covers folders nobody ever opened —
    /// including repos cloned into it long after it was trusted.
    private var inherited: Bool {
        guard let decidedAt = state.decidedAt else { return false }
        return decidedAt != state.workspace
    }

    private var title: LocalizedStringKey {
        notice == .undisclosedGrant ? "This project is already trusted" : "This project ships pi resources"
    }

    private var detail: LocalizedStringKey {
        switch notice {
        case .undisclosedGrant:
            return inherited
                ? "A parent folder was trusted, so pi will load this repo's own configuration and run any extensions it ships. pi won't start until you answer."
                : "pi will load this repo's own configuration and run any extensions it ships. pi won't start until you answer."
        case .undecided:
            return executes
                ? "pi is skipping them. Trusting this project runs the code it ships at every pi startup."
                : "pi is skipping them until you trust this project."
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Button("Review", action: onReview)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.warning)
                    .foregroundStyle(Theme.onAccent)
                    .disabled(disabled)
                // Dismissing is for this screen only and NEVER implies a decision:
                // an undecided project stays undecided, which is the safe state,
                // and a disclosed grant returns next time.
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
            .overlay(alignment: .center) {
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(14)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// The sheet's subject, captured when it opens so answering — which clears the
/// live notice — cannot empty it out mid-flight.
struct PiTrustSheetInput: Identifiable {
    let notice: SessionDetailViewModel.PiTrustNotice
    let state: PiProjectTrustState
    var id: String { state.workspace }
}

/// The full decision: what pi would load, where the verdict lives, and the
/// answers. pi resolves trust once at process startup, so an answer only reaches
/// a pi that is already up when that process next starts — which the sheet says
/// rather than implying the change is already live.
struct PiTrustSheet: View {
    let notice: SessionDetailViewModel.PiTrustNotice
    let state: PiProjectTrustState
    /// The decision has been made; nothing is left to ask. The answers come down
    /// and the sheet is only here to report the outcome.
    let answered: Bool
    let disabled: Bool
    let busy: Bool
    /// `true` grants, `false` declines, `nil` revokes an existing grant.
    let onDecide: (Bool?) -> Void
    /// Keep a grant that is already in force (acknowledge only).
    let onKeep: () -> Void
    let errorMessage: String?
    /// The answer was written but NEEDS pi restarted to take effect — not a claim
    /// about whether one is running, which nothing here can observe.
    let savedNotApplied: Bool

    @Environment(\.dismiss) private var dismiss

    private var inherited: Bool {
        guard let decidedAt = state.decidedAt else { return false }
        return decidedAt != state.workspace
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(state.workspace)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                    if inherited, let decidedAt = state.decidedAt {
                        LabeledContent("Decided at") {
                            Text(decidedAt)
                                .font(.footnote.monospaced())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    LabeledContent("Trust file") {
                        Text(state.trustFile)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                } header: {
                    Text("Project")
                }

                Section {
                    ForEach(state.resources) { resource in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(LocalizedStringKey(stringLiteral: resource.kind))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.textPrimary)
                                if resource.executesCode {
                                    Text("runs code")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Theme.warning.opacity(0.18), in: Capsule())
                                        .foregroundStyle(Theme.warning)
                                }
                            }
                            Text(resource.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("What pi would load")
                } footer: {
                    Text("Anything marked “runs code” executes at every pi startup, with your permissions, before you send anything.")
                }

                if let errorMessage {
                    Section { InlineErrorView(message: errorMessage) {} }
                }

                if savedNotApplied {
                    Section {
                        // Phrased conditionally on purpose: this client has no
                        // way to tell whether a pi is running for this session, so
                        // "pi is still on the old setting" would be a claim it
                        // cannot make. "Any pi already running" is true either way.
                        Label(
                            "Saved. pi reads this when it starts, so any pi already running for this session keeps the previous setting until it next starts.",
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    }
                }

                Section {
                    if answered {
                        // Answered, but the sheet is still up — which happens
                        // whenever the answer needs a restart to take effect.
                        // Offering the buttons again would invite re-answering a
                        // question that no longer exists.
                        Label("Decision saved.", systemImage: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                    } else if notice == .undisclosedGrant {
                        // The grant already stands; the two real answers are to
                        // confirm it (which releases the launch gate) or take it
                        // away. pi's own file is untouched by keeping it.
                        Button("Keep trusting this project", action: onKeep).disabled(disabled)
                        // Writes a DECLINE for this folder rather than deleting an
                        // entry. Deleting is the wrong instrument here: an
                        // inherited grant has no entry at this folder to delete,
                        // so the backend would no-op while clearing codeg's
                        // acknowledgement — leaving the grant standing, the launch
                        // still gated, and this notice back on the next open, with
                        // no way out. pi resolves the NEAREST decision, so an
                        // explicit "no" here overrides the ancestor. Per-entry
                        // deletion lives in Settings → Agents → Pi, where the row
                        // being removed is the entry itself.
                        Button("Stop trusting this project", role: .destructive) { onDecide(false) }
                            .disabled(disabled)
                    } else {
                        Button("Trust this project") { onDecide(true) }.disabled(disabled)
                        Button("Not this project") { onDecide(false) }.disabled(disabled)
                    }
                } footer: {
                    if !answered {
                        Text(inherited
                             ? "pi reads trust once, when it starts. Your answer applies to this folder and everything under it — the parent folder's own setting is left alone."
                             : "pi reads trust once, when it starts. Your answer applies to this folder and everything under it.")
                    }
                }
            }
            .navigationTitle("Project trust")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if busy { ProgressView().controlSize(.small) }
                    else { Button("Close") { dismiss() } }
                }
            }
        }
    }
}
