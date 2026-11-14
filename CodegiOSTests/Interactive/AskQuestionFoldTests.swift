import Testing
@testable import Codeg

/// The collapse rules of `src/components/chat/ask-question-card.test.tsx`
/// ("AskQuestionCard collapse", codeg 0.44).
struct AskQuestionFoldTests {
    @Test("opens by default")
    func opensByDefault() {
        let fold = AskQuestionFold(foldable: true)
        #expect(!fold.isCollapsed("q-1"))
    }

    @Test("the toggle folds and unfolds the same set")
    func togglesRoundTrip() {
        var fold = AskQuestionFold(foldable: true)
        fold.toggle("q-1")
        #expect(fold.isCollapsed("q-1"))
        fold.toggle("q-1")
        #expect(!fold.isCollapsed("q-1"))
    }

    @Test("re-rendering the same set keeps it folded")
    func survivesSameSet() {
        var fold = AskQuestionFold(foldable: true)
        fold.toggle("q-1")
        fold.present("q-1")
        #expect(fold.isCollapsed("q-1"))
    }

    @Test("the read-only view never folds")
    func readOnlyNeverFolds() {
        var fold = AskQuestionFold(foldable: false)
        fold.toggle("q-1")
        #expect(!fold.isCollapsed("q-1"))
    }

    @Test("a different question set reads as open from its first render")
    func newSetOpensBeforePresent() {
        var fold = AskQuestionFold(foldable: true)
        fold.toggle("q-1")
        // No `present` yet: the new set must not render folded even for a frame.
        #expect(!fold.isCollapsed("q-2"))
    }

    @Test("a replaced set does not resurface folded if it comes back")
    func swapClearsForGood() {
        var fold = AskQuestionFold(foldable: true)
        fold.toggle("q-1")
        fold.present("q-2")
        #expect(!fold.isCollapsed("q-2"))
        fold.present("q-1")
        #expect(!fold.isCollapsed("q-1"))
    }

    @Test("folding a replacement set works on its own id")
    func foldsReplacementSet() {
        var fold = AskQuestionFold(foldable: true)
        fold.toggle("q-1")
        fold.present("q-2")
        fold.toggle("q-2")
        #expect(fold.isCollapsed("q-2"))
    }

    @Test("a failed submit opens the card again")
    func submitFailureOpens() {
        var fold = AskQuestionFold(foldable: true)
        fold.toggle("q-1")
        fold.submitFailed()
        #expect(!fold.isCollapsed("q-1"))
    }
}
