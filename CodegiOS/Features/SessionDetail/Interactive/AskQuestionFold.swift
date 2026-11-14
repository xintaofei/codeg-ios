import Foundation

/// Whether the live blocking question card is folded down to its title row.
/// Mirrors codeg 0.44 web's `collapsed` state in `ask-question-card.tsx`:
///
/// - Only the live (blocking) card folds. The read-only replay inside an
///   answered record has its own expand/collapse capsule
///   (`AskQuestionResultCard`), so a second toggle there would fight it.
/// - The fold belongs to one question set. A replacement set (a different
///   question id) is a NEW blocking request; left folded it would read as the
///   same title row the user already put away, and the agent would sit stalled
///   on an answer nobody knows it asked for. So a new id always opens.
/// - A failed submit opens the card again: the footer carries both the error
///   line and the retry, so a failure while folded would leave a still-blocking
///   question looking answered.
///
/// Selections are not part of this — folding only hides the body, so picks
/// survive a fold/unfold round-trip.
struct AskQuestionFold: Equatable {
    /// False for the read-only replay: it never folds and offers no toggle.
    let foldable: Bool
    /// The question set the user folded; `nil` while open. Keyed by id so a
    /// different set reads as open from its very first render, before any
    /// change handler has run.
    private var foldedQuestionId: String?

    init(foldable: Bool) {
        self.foldable = foldable
    }

    func isCollapsed(_ questionId: String) -> Bool {
        foldable && foldedQuestionId == questionId
    }

    /// The header toggle.
    mutating func toggle(_ questionId: String) {
        guard foldable else { return }
        foldedQuestionId = isCollapsed(questionId) ? nil : questionId
    }

    /// A question set rendered into this card. A different one clears the fold
    /// for good, so the old set coming back later does not resurface folded.
    mutating func present(_ questionId: String) {
        if foldedQuestionId != questionId { foldedQuestionId = nil }
    }

    /// The answer (or skip) round-trip failed: open back up so the error line
    /// and the retry are where the user can see them.
    mutating func submitFailed() {
        foldedQuestionId = nil
    }
}
