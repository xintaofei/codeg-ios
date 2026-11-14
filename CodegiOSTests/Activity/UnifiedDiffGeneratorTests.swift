import Foundation
import Testing
@testable import Codeg

/// `src/lib/unified-diff-generator.test.ts` — the diff generator and line
/// counters ``ActivityEdit`` draws on.
struct UnifiedDiffGeneratorTests {
    private func makeLines(_ count: Int, _ label: String = "line") -> [String] {
        (1...count).map { "\(label) \($0)" }
    }

    /// Diff body lines (the `--- a/` / `+++ b/` file header excluded).
    private func bodyLineCount(_ diff: String) -> Int {
        diff.components(separatedBy: "\n").filter { !$0.hasPrefix("--- ") && !$0.hasPrefix("+++ ") }.count
    }

    private func hunkCount(_ diff: String) -> Int {
        diff.components(separatedBy: "\n").filter { $0.hasPrefix("@@ ") }.count
    }

    private func generate(_ old: String, _ new: String, _ path: String? = nil) -> String? {
        UnifiedDiffGenerator.generateUnifiedDiff(old, new, filePath: path)
    }

    @Test("returns null when there is no change")
    func nullWhenNoChange() {
        #expect(generate("a\nb\nc", "a\nb\nc") == nil)
        #expect(generate("", "") == nil)
        // Differs only by a trailing newline → both normalize away.
        #expect(generate("a\nb\n", "a\nb") == nil)
    }

    @Test("keeps a one-line change in a 1000-line file compact")
    func compactOneLineChange() throws {
        let oldLines = makeLines(1000)
        var newLines = oldLines
        newLines[499] = "CHANGED line 500"
        let text = try #require(generate(oldLines.joined(separator: "\n"), newLines.joined(separator: "\n"), "big.ts"))
        #expect(bodyLineCount(text) < 20)
        #expect(text.contains("@@ -497,7 +497,7 @@"))
        #expect(text.contains("-line 500"))
        #expect(text.contains("+CHANGED line 500"))
        #expect(!text.contains("line 800"))
        #expect(!text.contains("line 200"))
    }

    @Test("emits separate compact hunks for scattered changes, skipping the gap")
    func scatteredChanges() throws {
        let oldLines = makeLines(1000)
        var newLines = oldLines
        newLines[1] = "CHANGED line 2"
        newLines[898] = "CHANGED line 899"
        let text = try #require(generate(oldLines.joined(separator: "\n"), newLines.joined(separator: "\n"), "big.ts"))
        #expect(hunkCount(text) == 2)
        #expect(bodyLineCount(text) < 40)
        #expect(!text.contains("line 500"))
        #expect(text.contains("+CHANGED line 2"))
        #expect(text.contains("+CHANGED line 899"))
    }

    @Test("renders a pure insertion with no deletion lines and correct anchoring")
    func pureInsertion() throws {
        let oldLines = makeLines(10)
        let newLines = Array(oldLines[0..<5]) + ["inserted line"] + Array(oldLines[5...])
        let text = try #require(generate(oldLines.joined(separator: "\n"), newLines.joined(separator: "\n"), "f.ts"))
        #expect(LineChangeStats.countUnifiedDiffLineChanges(text) == LineChangeStats(additions: 1, deletions: 0))
        #expect(text.contains("+inserted line"))
        #expect(text.contains("@@ -3,6 +3,7 @@"))
    }

    @Test("renders a pure deletion with no addition lines")
    func pureDeletion() throws {
        let oldLines = makeLines(10)
        let newLines = oldLines.enumerated().filter { $0.offset != 4 }.map(\.element)
        let text = try #require(generate(oldLines.joined(separator: "\n"), newLines.joined(separator: "\n"), "f.ts"))
        #expect(LineChangeStats.countUnifiedDiffLineChanges(text) == LineChangeStats(additions: 0, deletions: 1))
        #expect(text.contains("-line 5"))
    }

    @Test("offsets a later hunk's +start by earlier insertions")
    func offsetsLaterHunk() throws {
        let oldLines = makeLines(200)
        var newLines = oldLines
        newLines[149] = "CHANGED line 150"
        newLines.insert("INSERTED", at: 2)
        let text = try #require(generate(oldLines.joined(separator: "\n"), newLines.joined(separator: "\n"), "f.ts"))
        #expect(hunkCount(text) == 2)
        #expect(text.contains("@@ -1,5 +1,6 @@"))
        #expect(text.contains("@@ -147,7 +148,7 @@"))
    }

    @Test("falls back to a complete naive diff for a true large rewrite")
    func naiveFallback() throws {
        let oldText = makeLines(2500, "old").joined(separator: "\n")
        let newText = makeLines(2500, "new").joined(separator: "\n")
        let text = try #require(generate(oldText, newText, "rewrite.ts"))
        #expect(text.contains("@@ -1,2500 +1,2500 @@"))
        #expect(LineChangeStats.countUnifiedDiffLineChanges(text) == LineChangeStats(additions: 2500, deletions: 2500))
    }

    @Test("counts body lines whose content starts with +++/---")
    func markerBodyLines() throws {
        let oldText = ["keep", "--- old marker", "keep2"].joined(separator: "\n")
        let newText = ["keep", "+++ new marker", "keep2"].joined(separator: "\n")
        let text = try #require(generate(oldText, newText, "f.ts"))
        #expect(text.contains("---- old marker"))
        #expect(text.contains("++++ new marker"))
        #expect(LineChangeStats.countUnifiedDiffLineChanges(text) == LineChangeStats(additions: 1, deletions: 1))
    }

    @Test("agrees with estimateChangedLineStats on +/- counts")
    func agreesWithEstimate() throws {
        let bigOld = makeLines(1000)
        var bigNew = bigOld
        bigNew[499] = "CHANGED line 500"

        let offOld = makeLines(200)
        var offNew = offOld
        offNew[149] = "CHANGED line 150"
        offNew.insert("INSERTED", at: 2)

        let dupPrefix = Array(repeating: "x", count: 500)
        let dupOld = dupPrefix + ["old one", "shared middle", "old two"]
        let dupNew = dupPrefix + ["new one", "shared middle", "new two"]

        let sameBlock = Array(repeating: "same", count: 500)
        let dupInnerOld = (["old-start"] + sameBlock + ["old-end"]).joined(separator: "\n")
        let dupInnerNew = (["new-start"] + sameBlock + ["new-end"]).joined(separator: "\n")

        let sparseOld = (makeLines(500, "old-before") + ["shared"] + makeLines(500, "old-after")).joined(separator: "\n")
        let sparseNew = (makeLines(500, "new-before") + ["shared"] + makeLines(500, "new-after")).joined(separator: "\n")

        let markerOld = ["keep", "--- old marker", "keep2"].joined(separator: "\n")
        let markerNew = ["keep", "+++ new marker", "keep2"].joined(separator: "\n")

        let cases: [(String, String)] = [
            ("a\nb\nc\nd", "a\nB\nc\nd"),
            ("a\nb\nc", "a\nx\ny\nc"),
            ("one\ntwo\nthree\nfour\nfive", "one\nthree\nfour"),
            (bigOld.joined(separator: "\n"), bigNew.joined(separator: "\n")),
            (offOld.joined(separator: "\n"), offNew.joined(separator: "\n")),
            (dupOld.joined(separator: "\n"), dupNew.joined(separator: "\n")),
            (dupInnerOld, dupInnerNew),
            (sparseOld, sparseNew),
            (markerOld, markerNew),
            ("-- old marker", "++ new marker"),
        ]
        for (oldText, newText) in cases {
            let diff = try #require(generate(oldText, newText))
            #expect(LineChangeStats.countUnifiedDiffLineChanges(diff) == LineChangeStats.estimateChangedLineStats(oldText, newText))
        }
    }

    // iOS-only: JavaScript `===` compares code units; Swift's `==` would
    // equate a precomposed and a decomposed é and report no change.
    @Test("treats canonically equivalent but different lines as changed")
    func codeUnitEquality() {
        #expect(generate("caf\u{E9}", "cafe\u{301}") != nil)
        #expect(LineChangeStats.estimateChangedLineStats("caf\u{E9}", "cafe\u{301}") == LineChangeStats(additions: 1, deletions: 1))
    }
}
