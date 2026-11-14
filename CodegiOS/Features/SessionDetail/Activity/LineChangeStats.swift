import Foundation

/// Added/removed line counts of an edit, and the functions that produce them —
/// port of the web's `src/lib/line-change-stats.ts` (codeg 0.44).
///
/// The collapsed `+N −M` stat (``estimateChangedLineStats(_:_:)``) and the
/// expanded diff (``UnifiedDiffGenerator/generateUnifiedDiff(_:_:filePath:contextLines:)``)
/// trim the same common outer lines and share one LCS budget, so they always
/// report the same counts.
///
/// Lines compare by code unit (JavaScript `===`), never by Swift's canonical
/// equivalence: a precomposed and a decomposed `é` are different lines here,
/// as they are on the web.
struct LineChangeStats: Equatable, Hashable, Sendable {
    var additions: Int
    var deletions: Int
}

extension LineChangeStats {
    /// Maximum product of changed-window line counts before both the collapsed
    /// stat and the expanded diff stop computing an exact diff and treat the
    /// whole window as changed. The number of matching line pairs is ≤ the
    /// product, so one budget bounds both the LIS here and the O(n·m) diff
    /// table — and makes the two share ONE fallback trigger, so they can never
    /// disagree. Kept modest because the stat runs on every edit-row render.
    static let lineDiffLCSBudget = 1_000_000

    /// Whether a changed window is too large for an exact line LCS. Shared by
    /// the collapsed stat and `generateUnifiedDiff` so they fall back in lockstep.
    static func exceedsLineDiffBudget(_ oldWindow: [String], _ newWindow: [String]) -> Bool {
        oldWindow.count * newWindow.count > lineDiffLCSBudget
    }

    /// `text.split("\n")` less one trailing empty piece; `[]` for `""`. Splits
    /// on the `\n` scalar, so a CRLF text keeps its `\r` on each line.
    static func splitNormalizedLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = ActivityCommand.JS.split(text, "\n")
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }

    /// The changed window: both sides less their common leading/trailing lines.
    /// Mirrors the trimming in `generateUnifiedDiff`.
    static func trimCommonOuterLines(_ oldLines: [String], _ newLines: [String])
        -> (oldWindow: [String], newWindow: [String]) {
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count,
              ActivityCommand.JS.strictEquals(oldLines[prefix], newLines[prefix]) {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              ActivityCommand.JS.strictEquals(oldLines[oldLines.count - 1 - suffix],
                                              newLines[newLines.count - 1 - suffix]) {
            suffix += 1
        }
        return (Array(oldLines[prefix..<(oldLines.count - suffix)]),
                Array(newLines[prefix..<(newLines.count - suffix)]))
    }

    private static func lowerBound(_ values: [Int], _ target: Int) -> Int {
        var left = 0, right = values.count
        while left < right {
            let mid = left + ((right - left) >> 1)
            if values[mid] < target { left = mid + 1 } else { right = mid }
        }
        return left
    }

    /// LCS length by line, as the longest increasing subsequence of matching
    /// new-side positions.
    private static func lcsLengthByLine(_ oldLines: [String], _ newLines: [String]) -> Int {
        // Keyed by UTF-8 bytes: a `String` key would merge canonically
        // equivalent lines that JavaScript's `Map` keeps apart.
        var positions: [[UInt8]: [Int]] = [:]
        for (i, line) in newLines.enumerated() {
            positions[Array(line.utf8), default: []].append(i)
        }
        var lis: [Int] = []
        for line in oldLines {
            guard let bucket = positions[Array(line.utf8)], !bucket.isEmpty else { continue }
            for pos in bucket.reversed() {
                let at = lowerBound(lis, pos)
                if at == lis.count { lis.append(pos) } else { lis[at] = pos }
            }
        }
        return lis.count
    }

    /// Added/removed lines between two texts, by line LCS over the changed
    /// window (the whole window when it exceeds the budget).
    static func estimateChangedLineStats(_ oldText: String, _ newText: String) -> LineChangeStats {
        let oldLines = splitNormalizedLines(oldText)
        let newLines = splitNormalizedLines(newText)

        if oldLines.isEmpty, newLines.isEmpty { return LineChangeStats(additions: 0, deletions: 0) }
        if oldLines.isEmpty { return LineChangeStats(additions: newLines.count, deletions: 0) }
        if newLines.isEmpty { return LineChangeStats(additions: 0, deletions: oldLines.count) }

        // Trimmed first so the estimate runs on the same window the unified
        // diff renders from; equal to diffing the full text on the LCS path,
        // and keeps the two in step when the budget fallback applies.
        let (oldWindow, newWindow) = trimCommonOuterLines(oldLines, newLines)
        if oldWindow.isEmpty { return LineChangeStats(additions: newWindow.count, deletions: 0) }
        if newWindow.isEmpty { return LineChangeStats(additions: 0, deletions: oldWindow.count) }

        if exceedsLineDiffBudget(oldWindow, newWindow) {
            return LineChangeStats(additions: newWindow.count, deletions: oldWindow.count)
        }

        let lcs = lcsLengthByLine(oldWindow, newWindow)
        return LineChangeStats(additions: max(0, newWindow.count - lcs),
                               deletions: max(0, oldWindow.count - lcs))
    }

    // JS `\d` is ASCII; ICU's is Unicode — spelled `[0-9]`.
    private static let unifiedHunkHeaderRE = ActivityCommand.JS.regex(
        #"^@@ -[0-9]+(?:,([0-9]+))? \+[0-9]+(?:,([0-9]+))? @@"#
    )

    /// Added/removed lines of a unified diff text.
    ///
    /// With `@@` hunks, each hunk consumes exactly the old/new line counts it
    /// declares, so a body line whose content begins with `--- `/`+++ ` is
    /// counted by POSITION rather than mistaken for a file header. Without
    /// hunks (a header-less `+`/`-` block), a prefix scan that skips the
    /// `--- `/`+++ ` header lines.
    static func countUnifiedDiffLineChanges(_ text: String) -> LineChangeStats {
        let lines = ActivityCommand.JS.split(text, "\n")
        let JS = ActivityCommand.JS.self

        if lines.contains(where: { JS.test(unifiedHunkHeaderRE, $0) }) {
            var additions = 0, deletions = 0
            var i = 0
            while i < lines.count {
                let header = JS.match(unifiedHunkHeaderRE, lines[i])
                i += 1
                guard let header else { continue }
                // Omitted count means 1 (`@@ -a +c @@`). Doubles, as JavaScript
                // numbers: a count too long for an Int must not trap.
                var oldRemaining = header[1].flatMap { Double($0) } ?? 1
                var newRemaining = header[2].flatMap { Double($0) } ?? 1
                while i < lines.count, oldRemaining > 0 || newRemaining > 0 {
                    let line = lines[i]
                    i += 1
                    if JS.startsWith(line, "\\") { continue } // "\ No newline at end of file"
                    if JS.startsWith(line, "-") {
                        deletions += 1
                        oldRemaining -= 1
                    } else if JS.startsWith(line, "+") {
                        additions += 1
                        newRemaining -= 1
                    } else {
                        oldRemaining -= 1
                        newRemaining -= 1
                    }
                }
            }
            return LineChangeStats(additions: additions, deletions: deletions)
        }

        var additions = 0, deletions = 0
        for line in lines {
            if JS.startsWith(line, "+"), !JS.startsWith(line, "+++ ") { additions += 1 }
            if JS.startsWith(line, "-"), !JS.startsWith(line, "--- ") { deletions += 1 }
        }
        return LineChangeStats(additions: additions, deletions: deletions)
    }
}

extension ActivityCommand.JS {
    /// JavaScript `a === b` on strings: code-unit equality. Swift's `==` is
    /// canonical equivalence, which would equate `"e\u{301}"` and `"é"`.
    static func strictEquals(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    /// JavaScript `s.includes(sub)`: a code-unit search. Swift's
    /// `String.contains` matches whole `Character`s, so it misses a needle
    /// whose last scalar is followed by a combining mark.
    static func includes(_ s: String, _ sub: String) -> Bool {
        if sub.isEmpty { return true }
        return (s as NSString).range(of: sub, options: .literal).location != NSNotFound
    }
}
