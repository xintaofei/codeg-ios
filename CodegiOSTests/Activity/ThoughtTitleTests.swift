import Testing
@testable import Codeg

/// `src/lib/activity/thought.test.ts`.
struct ThoughtTitleTests {
    private static let summary = [
        "**Summarizing log status**",
        "",
        "I need to gather the logs.",
        "",
        "**Checking the Makefile**",
        "",
        "The docs target is missing.",
    ].joined(separator: "\n")

    // MARK: thoughtTitle

    @Test func thoughtTitleUsesTheFirstHeadingOnceTheThoughtIsDone() {
        #expect(ThoughtTitle.thoughtTitle(Self.summary, streaming: false) == "Summarizing log status")
    }

    @Test func thoughtTitleUsesTheNewestHeadingWhileItIsStillBeingWritten() {
        #expect(ThoughtTitle.thoughtTitle(Self.summary, streaming: true) == "Checking the Makefile")
    }

    @Test func thoughtTitleAcceptsAtxHeadingsAndIgnoresFencedCode() {
        #expect(ThoughtTitle.thoughtTitle("```\n# not a title\n```\n## Real title\nbody", streaming: false) == "Real title")
    }

    @Test func thoughtTitleFallsBackToTheFirstSentence() {
        #expect(ThoughtTitle.thoughtTitle("Let me look at the parser first. Then the tests.", streaming: false)
            == "Let me look at the parser first")
        #expect(ThoughtTitle.thoughtTitle("- `foo` is broken\nmore", streaming: false) == "foo is broken")
    }

    @Test func thoughtTitleClipsLongTitles() {
        let title = ThoughtTitle.thoughtTitle(String(repeating: "x", count: 80), streaming: false)
        #expect(title?.count == 60)
        #expect(title?.hasSuffix("…") == true)
    }

    @Test func thoughtTitleIsNilForAnEmptyThought() {
        #expect(ThoughtTitle.thoughtTitle("  \n ", streaming: false) == nil)
    }

    // MARK: thoughtBodyWithoutTitle

    @Test func thoughtBodyWithoutTitleDropsTheHeadingTheRowAlreadyShows() {
        let expected = Self.summary.components(separatedBy: "\n").dropFirst(2).joined(separator: "\n")
        #expect(ThoughtTitle.thoughtBodyWithoutTitle(Self.summary, title: "Summarizing log status") == expected)
    }

    @Test func thoughtBodyWithoutTitleKeepsTheBodyWhenTheTitleCameFromElsewhere() {
        let content = "Plain reasoning text."
        #expect(ThoughtTitle.thoughtBodyWithoutTitle(content, title: "Plain reasoning text") == content)
    }
}
