import Foundation

/// Unified diff text from an old/new text pair — port of the web's
/// `src/lib/unified-diff-generator.ts`, with the LCS line diff it draws on
/// (`computeLineDiff` from `src/components/merge/merge-diff.ts`) (codeg 0.44).
///
/// Lines compare by code unit (JavaScript `===`), not by Swift's canonical
/// equivalence.
enum UnifiedDiffGenerator {
    /// One change region of a line diff (web `DiffHunk`).
    struct Hunk: Equatable, Sendable {
        /// Start index in the old array, 0-based.
        var baseStart: Int
        /// Lines removed from the old side (0 = pure insertion).
        var baseCount: Int
        /// Replacement lines from the new side.
        var newLines: [String]
    }

    /// A unified diff of `oldText → newText`, headed `--- a/<path>` /
    /// `+++ b/<path>` (`file` when no path is given); nil when nothing changed.
    ///
    /// Only the changed window is diffed: the common leading/trailing lines are
    /// trimmed first, so a small edit inside a large file (the full-file
    /// old/new strings a Codex ACP edit synthesizes) stays a compact hunk
    /// instead of tripping the budget and dumping the whole file. The budget
    /// gate is shared with ``LineChangeStats/estimateChangedLineStats(_:_:)``.
    static func generateUnifiedDiff(_ oldText: String, _ newText: String,
                                    filePath: String? = nil, contextLines: Int = 3) -> String? {
        if oldText.isEmpty, newText.isEmpty { return nil }
        if ActivityCommand.JS.strictEquals(oldText, newText) { return nil }

        let oldLines = oldText.isEmpty ? [] : LineChangeStats.splitNormalizedLines(oldText)
        let newLines = newText.isEmpty ? [] : LineChangeStats.splitNormalizedLines(newText)

        let path = filePath ?? "file"
        let header = "--- a/\(path)\n+++ b/\(path)"

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

        let midOld = Array(oldLines[prefix..<(oldLines.count - suffix)])
        let midNew = Array(newLines[prefix..<(newLines.count - suffix)])

        // Nothing left after trimming (content differed only by a trailing newline).
        if midOld.isEmpty, midNew.isEmpty { return nil }

        if LineChangeStats.exceedsLineDiffBudget(midOld, midNew) {
            return buildNaiveDiff(header, midOld, midNew, windowStart: prefix)
        }

        let hunks = computeLineDiff(midOld, midNew)
        if hunks.isEmpty { return nil }

        // Window-relative → full-file positions, so context comes from the full old array.
        let offsetHunks = prefix == 0 ? hunks : hunks.map {
            Hunk(baseStart: $0.baseStart + prefix, baseCount: $0.baseCount, newLines: $0.newLines)
        }
        return "\(header)\n\(buildUnifiedHunks(oldLines, offsetHunks, contextLines))"
    }

    /// All deletions, then all additions, under one hunk header whose numbers
    /// are real file lines (`windowStart` is the window's 0-based offset).
    private static func buildNaiveDiff(_ header: String, _ oldLines: [String], _ newLines: [String],
                                       windowStart: Int) -> String {
        let oldStart = oldLines.isEmpty ? 0 : windowStart + 1
        let newStart = newLines.isEmpty ? 0 : windowStart + 1
        var parts = [header, "@@ -\(oldStart),\(oldLines.count) +\(newStart),\(newLines.count) @@"]
        for line in oldLines { parts.append("-\(line)") }
        for line in newLines { parts.append("+\(line)") }
        return parts.joined(separator: "\n")
    }

    /// Hunks rendered with `contextLines` of context, nearby hunks whose
    /// context windows overlap merged into one, like `diff -u`.
    private static func buildUnifiedHunks(_ oldLines: [String], _ hunks: [Hunk], _ contextLines: Int) -> String {
        struct Group { var ctxOldStart: Int; var ctxOldEnd: Int; var hunks: [Hunk] }
        var merged: [Group] = []
        for hunk in hunks {
            let ctxOldStart = max(0, hunk.baseStart - contextLines)
            let ctxOldEnd = min(oldLines.count, hunk.baseStart + hunk.baseCount + contextLines)
            if var last = merged.last, ctxOldStart <= last.ctxOldEnd {
                last.ctxOldEnd = max(last.ctxOldEnd, ctxOldEnd)
                last.hunks.append(hunk)
                merged[merged.count - 1] = last
            } else {
                merged.append(Group(ctxOldStart: ctxOldStart, ctxOldEnd: ctxOldEnd, hunks: [hunk]))
            }
        }

        var output: [String] = []
        // Net (additions − deletions) of every earlier group: a later hunk's
        // `+start` is its old start shifted by it.
        var newLineDelta = 0
        for group in merged {
            var lines: [String] = []
            var oldCursor = group.ctxOldStart
            var newLineCount = 0
            var groupDelta = 0
            let oldLineCount = group.ctxOldEnd - group.ctxOldStart

            for hunk in group.hunks {
                while oldCursor < hunk.baseStart {
                    lines.append(" \(oldLines[oldCursor])")
                    newLineCount += 1
                    oldCursor += 1
                }
                for i in 0..<hunk.baseCount {
                    lines.append("-\(oldLines[hunk.baseStart + i])")
                    oldCursor += 1
                }
                for newLine in hunk.newLines {
                    lines.append("+\(newLine)")
                    newLineCount += 1
                }
                groupDelta += hunk.newLines.count - hunk.baseCount
            }
            while oldCursor < group.ctxOldEnd {
                lines.append(" \(oldLines[oldCursor])")
                newLineCount += 1
                oldCursor += 1
            }

            let oldStart = oldLineCount == 0 ? 0 : group.ctxOldStart + 1
            let newStart = newLineCount == 0 ? 0 : group.ctxOldStart + 1 + newLineDelta
            output.append("@@ -\(oldStart),\(oldLineCount) +\(newStart),\(newLineCount) @@")
            output.append(contentsOf: lines)
            newLineDelta += groupDelta
        }
        return output.joined(separator: "\n")
    }

    // MARK: - LCS line diff (web `merge-diff.ts`)

    private enum OpKind { case equal, delete, insert }
    private struct EditOp { var kind: OpKind; var aIdx: Int; var bIdx: Int }

    /// Line-level change regions between `a` (old) and `b` (new).
    static func computeLineDiff(_ a: [String], _ b: [String]) -> [Hunk] {
        // Lines interned to ids by their bytes: exact code-unit equality, and
        // the O(m·n) table compares integers.
        var ids: [[UInt8]: Int] = [:]
        func intern(_ line: String) -> Int {
            let key = Array(line.utf8)
            if let id = ids[key] { return id }
            let id = ids.count
            ids[key] = id
            return id
        }
        let ai = a.map(intern), bi = b.map(intern)
        let m = ai.count, n = bi.count
        let width = n + 1

        // dp[i][j] = LCS length of a[0..<i], b[0..<j].
        var dp = [Int](repeating: 0, count: (m + 1) * width)
        if m > 0, n > 0 {
            for i in 1...m {
                for j in 1...n {
                    dp[i * width + j] = ai[i - 1] == bi[j - 1]
                        ? dp[(i - 1) * width + j - 1] + 1
                        : max(dp[(i - 1) * width + j], dp[i * width + j - 1])
                }
            }
        }

        var ops: [EditOp] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0, ai[i - 1] == bi[j - 1] {
                ops.append(EditOp(kind: .equal, aIdx: i - 1, bIdx: j - 1))
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || dp[i * width + j - 1] >= dp[(i - 1) * width + j] {
                ops.append(EditOp(kind: .insert, aIdx: -1, bIdx: j - 1))
                j -= 1
            } else {
                ops.append(EditOp(kind: .delete, aIdx: i - 1, bIdx: -1))
                i -= 1
            }
        }
        ops.reverse()

        var hunks: [Hunk] = []
        var idx = 0
        while idx < ops.count {
            let op = ops[idx]
            if op.kind == .equal {
                idx += 1
                continue
            }
            var baseStart = op.kind == .delete ? op.aIdx : -1
            var baseCount = 0
            var newLines: [String] = []
            while idx < ops.count, ops[idx].kind != .equal {
                let cur = ops[idx]
                if cur.kind == .delete {
                    if baseStart == -1 { baseStart = cur.aIdx }
                    baseCount += 1
                } else {
                    // Pure insertion: anchor at the line after the last equal/delete.
                    if baseStart == -1 { baseStart = insertionPoint(ops, idx) }
                    newLines.append(b[cur.bIdx])
                }
                idx += 1
            }
            hunks.append(Hunk(baseStart: baseStart, baseCount: baseCount, newLines: newLines))
        }
        return hunks
    }

    private static func insertionPoint(_ ops: [EditOp], _ currentIdx: Int) -> Int {
        var k = currentIdx - 1
        while k >= 0 {
            if ops[k].kind == .equal || ops[k].kind == .delete { return ops[k].aIdx + 1 }
            k -= 1
        }
        return 0
    }
}
