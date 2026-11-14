import SwiftUI

/// The inline card for a `question_request` (`ask_user_question`). Pinned above
/// the compose bar while the agent is blocked. Mirrors codeg web's
/// `ask-question-card.tsx`: one or more questions, each single- (radio) or
/// multi-select (checkbox), with a free-text "Other", and a Skip / Submit footer.
/// Skip submits a declined answer (the agent uses its own judgment).
struct AskQuestionCard: View {
    let pending: PendingQuestion
    /// Submit (or decline) the answer. Returns true on success — the model then
    /// clears the card; false keeps it and re-enables the controls.
    let onAnswer: (QuestionAnswer) async -> Bool
    /// Read-only mode: pre-filled, non-interactive, no footer, no outer chrome.
    /// `AskQuestionResultCard` uses it to replay an answered question in-stream so
    /// the layout matches the interactive card exactly.
    var readOnly = false
    var titleOverride: LocalizedStringKey?
    var subtitleOverride: LocalizedStringKey?

    /// Sentinel key for the "Other" choice (kept out of the submitted labels —
    /// the typed text is sent instead).
    private static let otherKey = "\u{1}__codeg_other__"

    /// Per-question chosen keys: predefined option labels and/or `otherKey`.
    @State private var chosen: [String: Set<String>]
    @State private var otherText: [String: String]
    @State private var submitting = false
    @State private var failed = false
    /// Folded down to the title row (live card only) — see `AskQuestionFold`.
    @State private var fold: AskQuestionFold

    init(pending: PendingQuestion,
         onAnswer: @escaping (QuestionAnswer) async -> Bool,
         readOnly: Bool = false,
         initialSelections: [String: AskQuestionSelection] = [:],
         titleOverride: LocalizedStringKey? = nil,
         subtitleOverride: LocalizedStringKey? = nil) {
        self.pending = pending
        self.onAnswer = onAnswer
        self.readOnly = readOnly
        self.titleOverride = titleOverride
        self.subtitleOverride = subtitleOverride
        // Seed the selection state from a pre-filled record (read-only replay).
        var chosen: [String: Set<String>] = [:]
        var other: [String: String] = [:]
        for (qid, sel) in initialSelections {
            var keys = Set(sel.chosen)
            if !sel.otherText.isEmpty {
                keys.insert(AskQuestionCard.otherKey)
                other[qid] = sel.otherText
            }
            chosen[qid] = keys
        }
        _chosen = State(initialValue: chosen)
        _otherText = State(initialValue: other)
        _fold = State(initialValue: AskQuestionFold(foldable: !readOnly))
    }

    private var answeredCount: Int { pending.questions.filter(isAnswered).count }
    private var complete: Bool { pending.questions.allSatisfy(isAnswered) }
    /// Folded, the header row IS the card: the question stays pending and
    /// visible, but the message list gets its space back.
    private var collapsed: Bool { fold.isCollapsed(pending.questionId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !collapsed {
                questionsList
                    .allowsHitTesting(!readOnly)

                if failed, !readOnly {
                    Label("Couldn’t submit. Please try again.", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }

                // Dropped in the read-only view and while folded.
                if !readOnly { footer }
            }
        }
        .padding(collapsed ? 10 : 14)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg)
        .modifier(AskCardChrome(enabled: !readOnly))
        // The host keys this card by question id, but stay correct on our own if
        // a replacement set ever renders into the same instance.
        .onChange(of: pending.questionId) { _, id in fold.present(id) }
    }

    /// In stream (read-only) the card sits in a timeline row, which owns scrolling
    /// and width — so render the questions inline (no nested fixed-height scroller).
    /// Interactive, the card is pinned over the compose bar and caps its own height.
    @ViewBuilder private var questionsList: some View {
        let list = VStack(alignment: .leading, spacing: 16) {
            ForEach(pending.questions) { question in
                questionBlock(question)
            }
        }
        if readOnly {
            list
        } else {
            ScrollView { list }.frame(maxHeight: 360)
        }
    }

    // MARK: Header / footer

    /// Live, the header row is the fold toggle (a full-width target rather than
    /// just the chevron); read-only, it is plain text.
    @ViewBuilder private var header: some View {
        if fold.foldable {
            Button {
                withAnimation(Theme.Motion.expand) { fold.toggle(pending.questionId) }
            } label: {
                headerContent.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(collapsed ? Text("Collapsed") : Text("Expanded"))
            .accessibilityHint(collapsed ? "Expand" : "Collapse")
        } else {
            headerContent
        }
    }

    private var headerContent: some View {
        // Folded, the row centers on its single line rather than top-aligning
        // against a subtitle that is gone.
        HStack(alignment: collapsed ? .center : .top, spacing: 10) {
            Image(systemName: readOnly ? "questionmark.bubble.fill" : "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleOverride ?? "The agent needs your input")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if !collapsed {
                    if let subtitleOverride {
                        Text(subtitleOverride)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !readOnly {
                        Text("Answer below, then submit. You can skip anytime.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 8)
            if !readOnly, pending.questions.count > 1 {
                // Kept while folded: the row still says how far along the set
                // is, so a folded blocking question never reads as a dismissed one.
                Text(verbatim: "\(answeredCount)/\(pending.questions.count)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            if fold.foldable {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        // Lets the counter and chevron center on the row's own height.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { Task { await submit(.dismissed) } } label: {
                Text("Skip").font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .disabled(submitting)

            Spacer(minLength: 8)

            Button { Task { await submit(answer) } } label: {
                HStack(spacing: 6) {
                    if submitting { ProgressView().controlSize(.mini).tint(Theme.onAccent) }
                    Text("Submit").font(.subheadline.weight(.semibold))
                }
                .frame(minWidth: 96)
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .foregroundStyle(Theme.onAccent)
                .background(Theme.accent.opacity(complete ? 1 : 0.4), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!complete || submitting)
        }
    }

    // MARK: Question block

    private func questionBlock(_ question: QuestionSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(question.multiSelect ? "Multiple" : "Single")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                if pending.questions.count > 1, !question.header.isEmpty {
                    Text(verbatim: question.header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }

            Text(verbatim: question.question)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    optionRow(question, label: option.label, description: option.description)
                }
                // An option-less question IS a free-text one: just the input,
                // no "Other" to pick first. One whose bridge only accepts the
                // given option ids (`allowOther == false`) gets no input at all —
                // a typed answer could not be delivered.
                if question.options.isEmpty {
                    answerField(question)
                } else if question.allowOther {
                    otherRow(question)
                }
            }
        }
    }

    private func optionRow(_ question: QuestionSpec, label: String, description: String) -> some View {
        let selected = isSelected(question, label)
        return Button {
            toggle(question, label)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                indicator(selected: selected, multi: question.multiSelect)
                VStack(alignment: .leading, spacing: 2) {
                    // Strip a trailing " (Recommended)" for display (mirrors web
                    // `splitRecommended`); the full label stays the selection value.
                    let parts = AskQuestionParse.splitRecommended(label)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: parts.text)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if parts.recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.14), in: Capsule())
                        }
                    }
                    if !description.isEmpty {
                        Text(verbatim: description)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(rowBackground(selected), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .stroke(selected ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(submitting)
    }

    private func otherRow(_ question: QuestionSpec) -> some View {
        let selected = isSelected(question, Self.otherKey)
        return VStack(spacing: 6) {
            Button {
                toggle(question, Self.otherKey)
            } label: {
                HStack(spacing: 10) {
                    indicator(selected: selected, multi: question.multiSelect)
                    Text("Other")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(rowBackground(selected), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .stroke(selected ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(submitting)

            if selected { answerField(question) }
        }
    }

    /// The typed answer. Masked for a secret (an API key, say) — and then a
    /// single line, since `SecureField` has no vertical axis.
    @ViewBuilder
    private func answerField(_ question: QuestionSpec) -> some View {
        Group {
            if question.isSecret {
                SecureField("Type your answer…", text: otherBinding(question.id))
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                TextField("Type your answer…", text: otherBinding(question.id), axis: .vertical)
                    .lineLimit(1...3)
            }
        }
        .font(.subheadline)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm)
        .disabled(submitting)
    }

    private func indicator(selected: Bool, multi: Bool) -> some View {
        Image(systemName: multi
              ? (selected ? "checkmark.square.fill" : "square")
              : (selected ? "largecircle.fill.circle" : "circle"))
            .font(.system(size: 18))
            .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
    }

    private func rowBackground(_ selected: Bool) -> Color {
        selected ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.04)
    }

    // MARK: Selection state

    private func isSelected(_ question: QuestionSpec, _ key: String) -> Bool {
        chosen[question.id]?.contains(key) ?? false
    }

    private func toggle(_ question: QuestionSpec, _ key: String) {
        var set = chosen[question.id] ?? []
        if question.multiSelect {
            if set.contains(key) { set.remove(key) } else { set.insert(key) }
        } else {
            set = set.contains(key) ? [] : [key]   // single-select: replace / clear
        }
        chosen[question.id] = set
    }

    private func otherBinding(_ id: String) -> Binding<String> {
        Binding(get: { otherText[id] ?? "" }, set: { otherText[id] = $0 })
    }

    /// The selected option labels (+ any typed "Other" text) for a question.
    private func labels(for question: QuestionSpec) -> [String] {
        var set = chosen[question.id] ?? []
        let hasOther = set.remove(Self.otherKey) != nil
        // Labels only from what this question can actually submit: with
        // `allowOther == false` a stale "Other" (a replayed record) is dropped,
        // and an option-less question's input needs no selection to count.
        var result = Array(set)
        if question.options.isEmpty || (hasOther && question.allowOther) {
            let typed = otherText[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !typed.isEmpty { result.append(typed) }
        }
        return result
    }

    private func isAnswered(_ question: QuestionSpec) -> Bool {
        !labels(for: question).isEmpty
    }

    private var answer: QuestionAnswer {
        QuestionAnswer(
            answers: pending.questions.map { QuestionAnswerItem(questionId: $0.id, labels: labels(for: $0)) },
            declined: false
        )
    }

    private func submit(_ answer: QuestionAnswer) async {
        guard !submitting else { return }
        submitting = true
        failed = false
        let ok = await onAnswer(answer)
        if !ok {
            failed = true
            submitting = false
            // Folded mid-flight, the error line and the retry would be hidden.
            withAnimation(Theme.Motion.expand) { fold.submitFailed() }
        }
    }
}

/// The pinned interactive card floats with a shadow and its own outer insets; the
/// in-stream read-only replay drops both (the timeline row owns its insets).
private struct AskCardChrome: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .shadow(color: .black.opacity(0.14), radius: 12, y: 3)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        } else {
            content
        }
    }
}
