import Foundation
import Testing
@testable import Codeg

/// `JSON.stringify` for the fixtures.
func exploreFixtureJSON(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

/// `src/lib/activity/explore.test.ts` (codeg 0.44).
struct ReadLineCountTests {
    @Test("counts the content of the structured read shape")
    func countsTheContentOfTheStructuredReadShape() {
        #expect(ActivityExplore.readLineCount(exploreFixtureJSON(["start_line": 10, "content": "a\nb\nc\n"])) == 3)
    }

    @Test("counts raw text and codex's command envelope")
    func countsRawTextAndCodexsCommandEnvelope() {
        #expect(ActivityExplore.readLineCount("one\ntwo") == 2)
        #expect(ActivityExplore.readLineCount(exploreFixtureJSON(["formatted_output": "x\ny\nz", "exit_code": 0])) == 3)
    }

    @Test("is null when nothing came back")
    func isNullWhenNothingCameBack() {
        #expect(ActivityExplore.readLineCount("") == nil)
        #expect(ActivityExplore.readLineCount(nil) == nil)
    }
}

struct SearchResultTextTests {
    @Test("treats codex's empty exit-1 grep envelope as no matches")
    func treatsCodexsEmptyExit1GrepEnvelopeAsNoMatches() {
        #expect(ActivityExplore.searchResultText(
            toolName: "grep", output: nil,
            errorText: exploreFixtureJSON(["formatted_output": "", "exit_code": 1])) == "")
    }

    @Test("keeps a real grep failure out")
    func keepsARealGrepFailureOut() {
        #expect(ActivityExplore.searchResultText(toolName: "grep", output: nil, errorText: "rg: bad regex") == nil)
    }

    @Test("unwraps codex's envelope and passes other output through")
    func unwrapsCodexsEnvelopeAndPassesOtherOutputThrough() {
        #expect(ActivityExplore.searchResultText(
            toolName: "grep",
            output: exploreFixtureJSON(["formatted_output": "a.ts:1:x", "exit_code": 0]),
            errorText: nil) == "a.ts:1:x")
        #expect(ActivityExplore.searchResultText(toolName: "glob", output: "a.ts\nb.ts", errorText: nil) == "a.ts\nb.ts")
    }
}

struct SummarizeSearchResultTests {
    @Test("counts matched lines and the files they are in")
    func countsMatchedLinesAndTheFilesTheyAreIn() {
        #expect(ActivityExplore.summarizeSearchResult("src/a.ts:4:x\nsrc/a.ts:9:y\nsrc/b.ts:1:z")
            == .matches(matches: 3, files: 2))
    }

    @Test("counts files, ignoring Claude Code's Found preamble")
    func countsFilesIgnoringClaudeCodesFoundPreamble() {
        #expect(ActivityExplore.summarizeSearchResult("Found 2 files\n/repo/a.ts\n/repo/b.ts") == .files(files: 2))
    }

    @Test("reports no matches for empty output and Claude Code's empty notices")
    func reportsNoMatchesForEmptyOutputAndEmptyNotices() {
        #expect(ActivityExplore.summarizeSearchResult("") == ActivityExplore.SearchOutcome.none)
        #expect(ActivityExplore.summarizeSearchResult("No files found") == ActivityExplore.SearchOutcome.none)
        #expect(ActivityExplore.summarizeSearchResult("No matches found") == ActivityExplore.SearchOutcome.none)
    }

    @Test("falls back to result lines for output in neither shape")
    func fallsBackToResultLinesForOutputInNeitherShape() {
        #expect(ActivityExplore.summarizeSearchResult("3\n4") == .lines(lines: 2))
    }

    @Test("is null when there is no result yet")
    func isNullWhenThereIsNoResultYet() {
        #expect(ActivityExplore.summarizeSearchResult(nil) == nil)
    }
}
