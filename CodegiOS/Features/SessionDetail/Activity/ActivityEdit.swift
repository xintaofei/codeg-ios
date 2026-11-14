import Foundation

/// The diff an edit-like call's detail panel draws (web `EditDiff`).
struct EditDiff: Equatable, Hashable, Sendable {
    var text: String
    /// The hunk headers carry the file's real line numbers. False for a patch
    /// (codex's `@@` hunks have none) and for a diff generated from an old/new
    /// pair whose position in the file is unknown — numbering those from 1
    /// would point at the wrong lines.
    var numbered: Bool
    /// Drawn from an empty old text — a write's new content, a notebook cell's
    /// new source — so there is no "before" to set beside it. (The web leaves
    /// the field out rather than writing `false`.)
    var noBefore: Bool = false
}

/// File-edit payload readers — port of the web's `src/lib/activity/edit.ts`
/// (codeg 0.44): which files an edit touched, how many lines it added and
/// removed, and — when the agent reported real hunk positions — which lines
/// changed.
///
/// Edit payloads come in four shapes: codex's `*** Begin Patch` text, Claude
/// Code's `{file_path, old_string, new_string}`, codex's `{changes: {<path>:
/// …}}` map, and a plain unified diff.
///
/// JavaScript semantics kept explicit (see ``ActivityCommand/JS``): lines split
/// on the `\n` scalar (a CRLF text keeps its `\r`), `m`-flag `^`/`$` are
/// spelled as JavaScript line-terminator look-arounds (ICU's multiline mode
/// also breaks at VT, FF and NEL), `\d` is `[0-9]`, `/i` on ASCII patterns is an
/// ASCII-only fold, and string equality is by code unit. Where the web walks an
/// object in insertion order (`Object.entries` of a changes map), the order is
/// recovered from the source text.
enum ActivityEdit {
    private typealias JS = ActivityCommand.JS

    // MARK: - apply_patch text

    private enum ApplyPatchOp { case add, update, delete, move }

    private struct ApplyPatchFileStats {
        var op: ApplyPatchOp
        var path: String
        var from: String?
        var to: String?
        var additions: Int
        var deletions: Int
    }

    private static func parseApplyPatchDetailed(_ input: String)
        -> (files: [ApplyPatchFileStats], additions: Int, deletions: Int) {
        var files: [ApplyPatchFileStats] = []
        var currentFileIndex = -1
        var additions = 0
        var deletions = 0

        func header(_ line: String, _ prefix: String, _ op: ApplyPatchOp) -> Bool {
            guard JS.startsWith(line, prefix) else { return false }
            // The prefixes are ASCII, so dropping scalars drops UTF-16 units.
            let path = JS.trim(JS.sliceScalars(line, dropFirst: prefix.unicodeScalars.count, dropLast: 0))
            files.append(ApplyPatchFileStats(op: op, path: path, additions: 0, deletions: 0))
            currentFileIndex = files.count - 1
            return true
        }

        for line in JS.split(input, "\n") {
            if header(line, "*** Add File: ", .add) { continue }
            if header(line, "*** Update File: ", .update) { continue }
            if header(line, "*** Delete File: ", .delete) { continue }
            if JS.startsWith(line, "*** Move to: ") {
                let to = JS.trim(JS.sliceScalars(line, dropFirst: 13, dropLast: 0))
                if currentFileIndex >= 0 {
                    let current = files[currentFileIndex]
                    files[currentFileIndex].op = .move
                    files[currentFileIndex].path = "\(current.path) -> \(to)"
                    files[currentFileIndex].from = current.path
                    files[currentFileIndex].to = to
                }
                continue
            }
            if JS.startsWith(line, "+"), !JS.startsWith(line, "+++") {
                additions += 1
                if currentFileIndex >= 0 { files[currentFileIndex].additions += 1 }
                continue
            }
            if JS.startsWith(line, "-"), !JS.startsWith(line, "---") {
                deletions += 1
                if currentFileIndex >= 0 { files[currentFileIndex].deletions += 1 }
            }
        }
        return (files, additions, deletions)
    }

    // MARK: - JavaScript multiline anchors

    /// JavaScript's `^` under the `m` flag: input start or just after `\n`,
    /// `\r`, U+2028, U+2029. (ICU's multiline `^` also follows VT, FF, NEL.)
    private static let lineStart = #"(?:^|(?<=[\n\r\x{2028}\x{2029}]))"#
    /// JavaScript's `$` under the `m` flag.
    private static let lineEnd = #"(?=[\n\r\x{2028}\x{2029}]|\z)"#

    private static let diffGitRE = JS.regex(lineStart + #"diff --git "#)
    private static let minusHeaderRE = JS.regex(lineStart + #"--- "# + JS.dot + "+")
    private static let plusHeaderRE = JS.regex(lineStart + #"\+\+\+ "# + JS.dot + "+")
    /// `/^@@ /m`.
    private static let hunkLineRE = JS.regex(lineStart + #"@@ "#)
    /// `/^@@ -\d+/m` (web `NUMBERED_HUNK_RE`).
    private static let numberedHunkRE = JS.regex(lineStart + #"@@ -[0-9]"#)
    private static let plusDevNullRE = JS.regex(lineStart + #"\+\+\+ /dev/null"# + lineEnd)
    private static let minusDevNullRE = JS.regex(lineStart + #"--- /dev/null"# + lineEnd)
    /// `/^\+\+\+ ([^\n]+)$/gm`; `[^\n]+` is greedy and `$` holds before the
    /// `\n` it stops at, so the look-ahead is implied.
    private static let plusFileRE = JS.regex(lineStart + #"\+\+\+ ([^\n]+)"#)
    private static let abPrefixRE = JS.regex(#"^[ab]/"#)
    private static let patchBlockRE = JS.regex(
        #"(\*\*\* Begin Patch[\s\S]*?\*\*\* End Patch(?:\n|"# + lineEnd + "))"
    )

    /// Whether a text reads as a patch or unified diff (after undoing inline
    /// `\n`/`\t` escapes).
    static func looksLikeDiffPayload(_ input: String) -> Bool {
        if JS.trim(input).isEmpty { return false }
        let normalized = unescapeInlineEscapes(input)
        return JS.includes(normalized, "*** Begin Patch")
            || JS.includes(normalized, "*** Update File:")
            || JS.test(diffGitRE, normalized)
            || (JS.test(minusHeaderRE, normalized) && JS.test(plusHeaderRE, normalized))
            || JS.test(hunkLineRE, normalized)
    }

    /// Literal `\r\n`, `\n` and `\t` escape sequences turned into the
    /// characters they spell.
    static func unescapeInlineEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: #"\r\n"#, with: "\n", options: .literal)
            .replacingOccurrences(of: #"\n"#, with: "\n", options: .literal)
            .replacingOccurrences(of: #"\t"#, with: "\t", options: .literal)
    }

    private static func extractApplyPatchTextFromUnknownInput(_ input: String, _ parsed: [String: Any]?) -> String? {
        var candidates = [input]
        if let parsed, let command = ActivityCommand.commandFromUnknownValue(parsed) { candidates.append(command) }
        if let fallback = ActivityCommand.extractCommandFromUnknownInput(input) { candidates.append(fallback) }

        var seen = Set<[UInt8]>() // code-unit identity, as a JS `Set<string>`
        for rawCandidate in candidates {
            let candidate = JS.trim(rawCandidate)
            if candidate.isEmpty || !seen.insert(Array(candidate.utf8)).inserted { continue }

            var variants = [candidate]
            let unescaped = unescapeInlineEscapes(candidate)
            if !JS.strictEquals(unescaped, candidate) { variants.append(unescaped) }

            for variant in variants {
                if !JS.includes(variant, "*** Begin Patch") { continue }
                if let block = JS.match(patchBlockRE, variant)?[1], !block.isEmpty {
                    return JS.trim(block)
                }
                return JS.trim(variant)
            }
        }
        return nil
    }

    private static func isCanonicalEditPayload(_ parsed: [String: Any]) -> Bool {
        parsed["file_path"] is String
            || parsed["path"] is String
            || parsed["old_string"] is String
            || parsed["new_string"] is String
            || isTrue(parsed["replace_all"])
    }

    /// `value === true` — a JSON boolean, never the number 1.
    private static func isTrue(_ value: Any?) -> Bool {
        ActivityJSON.isBoolean(value) && (value as? NSNumber)?.boolValue == true
    }

    // MARK: - codex's changes map

    private struct EditChangePreview {
        var path: String
        var oldText: String
        var newText: String
        var unifiedDiff: String?
    }

    private static let editChangeOldKeys = [
        "old_string", "oldString", "old_text", "oldText", "old",
        "previous", "before", "source", "original",
    ]

    private static let editChangeNewKeys = [
        "new_string", "newString", "new_text", "newText", "new_content", "newContent",
        "new", "new_value", "newValue", "replacement", "after", "after_text", "afterText",
        "updated", "updated_text", "updatedText", "content", "new_source", "newSource", "text",
    ]

    private static let editChangeDiffKeys = ["diff", "patch", "unified_diff", "unifiedDiff"]

    /// Substrings of a key that suggest it holds change text (`/…/i` — the
    /// fold is ASCII-only in JavaScript, so the key is ASCII-lowercased).
    private static let likelyChangeKeyParts = ["old", "new", "before", "after", "content", "text", "source", "replace", "value"]
    /// Keys never treated as change text (`/^(…)$/i`, whole key).
    private static let nonChangeKeys: Set<String> = ["id", "status", "type", "call_id", "callid", "source", "auto_approved"]

    /// The non-empty string values of a change record whose key looks like
    /// change text, in source order; failing that, every non-empty string not
    /// under a bookkeeping key.
    private static func collectLikelyChangeStrings(_ value: [String: Any], source: String) -> [String] {
        let entries: [(String, String)] = jsObjectKeys(value, source: source).compactMap { key in
            guard let s = value[key] as? String, !s.isEmpty else { return nil }
            return (key, s)
        }
        if entries.isEmpty { return [] }

        let preferred = entries.filter { key, _ in
            let lower = asciiLowercased(key)
            return likelyChangeKeyParts.contains { JS.includes(lower, $0) }
        }.map(\.1)
        if !preferred.isEmpty { return preferred }

        return entries.filter { key, _ in !nonChangeKeys.contains(asciiLowercased(key)) }.map(\.1)
    }

    private static func firstStringField(_ value: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let field = value[key] as? String { return field }
        }
        return nil
    }

    private static func parseEditChangeValue(_ path: String, _ value: Any?, source: String) -> EditChangePreview? {
        if let s = value as? String {
            return EditChangePreview(path: path, oldText: "", newText: s)
        }
        guard let record = ActivityJSON.asObjectLike(value) else { return nil }

        let oldText = firstStringField(record, editChangeOldKeys)
            ?? ActivityJSON.findStringFieldDeep(record, key: "old_string")
            ?? ActivityJSON.findStringFieldDeep(record, key: "old_text")
            ?? ActivityJSON.findStringFieldDeep(record, key: "before_text")
            ?? ActivityJSON.findStringFieldDeep(record, key: "old")
            ?? ""
        let newText = firstStringField(record, editChangeNewKeys)
            ?? ActivityJSON.findStringFieldDeep(record, key: "new_string")
            ?? ActivityJSON.findStringFieldDeep(record, key: "new_text")
            ?? ActivityJSON.findStringFieldDeep(record, key: "after_text")
            ?? ActivityJSON.findStringFieldDeep(record, key: "new")
            ?? ""
        let unifiedDiff = firstStringField(record, editChangeDiffKeys)
            ?? ActivityJSON.findStringFieldDeep(record, key: "diff")
            ?? ""

        if !unifiedDiff.isEmpty {
            return EditChangePreview(path: path, oldText: oldText, newText: newText, unifiedDiff: unifiedDiff)
        }
        if !oldText.isEmpty || !newText.isEmpty {
            return EditChangePreview(path: path, oldText: oldText, newText: newText)
        }

        let fallbackStrings = collectLikelyChangeStrings(record, source: source)
        if fallbackStrings.count >= 2 {
            return EditChangePreview(path: path, oldText: fallbackStrings[0], newText: fallbackStrings[1])
        }
        if fallbackStrings.count == 1 {
            return EditChangePreview(path: path, oldText: "", newText: fallbackStrings[0])
        }
        return EditChangePreview(path: path, oldText: "", newText: "")
    }

    /// The `changes` map's entries, in the map's source order.
    private static func extractEditChangesPayload(_ parsed: [String: Any], source: String) -> [EditChangePreview] {
        guard let changes = ActivityJSON.findObjectFieldDeep(parsed, key: "changes") else { return [] }
        var items: [EditChangePreview] = []
        for path in jsObjectKeys(changes, source: source) {
            let normalizedPath = JS.trim(path)
            if normalizedPath.isEmpty { continue }
            if let item = parseEditChangeValue(normalizedPath, changes[path], source: source) {
                items.append(item)
            }
        }
        return items
    }

    // MARK: - line ranges

    // JS `\d` is ASCII; ICU's is Unicode.
    private static let hunkHeaderRE = JS.regex(#"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@"#)

    /// The span of new-file lines a unified diff changed. Walks each hunk with
    /// its own numbering, so context lines around the change are excluded: a
    /// 3-line context hunk at `+40,7` that adds lines 43–44 reports 43–44, not
    /// 40–46. A pure deletion reports the line the removed text used to precede.
    ///
    /// Counted in Doubles, as JavaScript numbers are, so an absurd header
    /// cannot trap; a result no `Int` can hold reads as nil.
    static func changedLineRangeFromUnifiedDiff(_ diff: String) -> ClosedRange<Int>? {
        var start = Double.infinity
        var end = 0.0
        var newLine = 0.0
        var inHunk = false
        var oldRemaining = 0.0
        var newRemaining = 0.0
        for line in JS.split(diff, "\n") {
            if let header = JS.match(hunkHeaderRE, line) {
                newLine = header[3].flatMap { Double($0) } ?? 0
                oldRemaining = header[2].flatMap { Double($0) } ?? 1
                newRemaining = header[4].flatMap { Double($0) } ?? 1
                inHunk = true
                continue
            }
            if !inHunk { continue }
            if oldRemaining <= 0, newRemaining <= 0 {
                inHunk = false
                continue
            }
            if JS.startsWith(line, "\\") { continue }
            if JS.startsWith(line, "+") {
                start = min(start, newLine)
                end = max(end, newLine)
                newLine += 1
                newRemaining -= 1
            } else if JS.startsWith(line, "-") {
                start = min(start, newLine)
                end = max(end, newLine)
                oldRemaining -= 1
            } else {
                newLine += 1
                oldRemaining -= 1
                newRemaining -= 1
            }
        }
        if !start.isFinite || start <= 0 { return nil }
        guard let lower = Int(exactly: start), let upper = Int(exactly: max(start, end)) else { return nil }
        return lower...upper
    }

    /// The changed new-file lines of an `old_string → new_string` replacement
    /// whose old text starts at `startLine`: common leading lines are not part
    /// of the change, so they move the start down.
    private static func changedRangeFromReplacement(_ oldText: String, _ newText: String,
                                                    startLine: Double) -> ClosedRange<Int>? {
        // `Number.isInteger(startLine) && startLine > 0`; beyond 2^53 a JS
        // number is no longer an exact line, and Swift could overflow.
        guard startLine > 0, startLine == startLine.rounded(), startLine <= 9_007_199_254_740_991,
              let line = Int(exactly: startLine) else { return nil }
        let oldLines = LineChangeStats.splitNormalizedLines(oldText)
        let newLines = LineChangeStats.splitNormalizedLines(newText)
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count,
              JS.strictEquals(oldLines[prefix], newLines[prefix]) {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              JS.strictEquals(oldLines[oldLines.count - 1 - suffix], newLines[newLines.count - 1 - suffix]) {
            suffix += 1
        }
        let changedNew = newLines.count - prefix - suffix
        let start = line + prefix
        return start...(start + max(changedNew, 1) - 1)
    }

    /// The `+++` paths of a unified diff, `a/`/`b/` prefixes off, `/dev/null` skipped.
    private static func unifiedDiffFiles(_ diff: String) -> [String] {
        let ns = diff as NSString
        var paths: [String] = []
        for m in plusFileRE.matches(in: diff, range: NSRange(location: 0, length: ns.length)) {
            let raw = JS.trim(ns.substring(with: m.range(at: 1)))
            if raw.isEmpty || raw == "/dev/null" { continue }
            paths.append(JS.replaceFirst(abPrefixRE, in: raw))
        }
        return paths
    }

    private static func changeFromUnifiedDiff(_ path: String, _ diff: String) -> EditFileChange {
        let stats = LineChangeStats.countUnifiedDiffLineChanges(diff)
        let removed = JS.test(plusDevNullRE, diff)
        let added = JS.test(minusDevNullRE, diff)
        return EditFileChange(
            path: path,
            op: removed ? .delete : added ? .add : .update,
            additions: stats.additions,
            deletions: stats.deletions,
            lineRange: removed ? nil : changedLineRangeFromUnifiedDiff(diff)
        )
    }

    // MARK: - per-file description (activity rows)

    /// Every file an edit-like tool call touched, with its line counts and
    /// changed span. `toolName` is the normalized name (`edit`, `write`,
    /// `apply_patch`, `notebookedit`); `output` is consulted for the unified
    /// diff some parsers put there (Claude Code's history rebuilds one from
    /// `structuredPatch`, with real line numbers).
    static func describeEditFiles(toolName: String, input: String?, output: String?) -> [EditFileChange] {
        let raw = input ?? ""
        // OpenCode's live stream spells the arguments in camelCase.
        let parsed = ToolNameNormalizer.aliasToolInputKeys(raw.isEmpty ? nil : ActivityJSON.tryParse(raw))

        let patchText = raw.isEmpty ? nil : extractApplyPatchTextFromUnknownInput(raw, parsed)
        // The patch may arrive with its newlines still JSON-escaped (a patch
        // nested in a JSON envelope the extractor could not unwrap), so the
        // unescaped form is tried too.
        let patchCandidates = patchText.map { [$0, unescapeInlineEscapes($0)] } ?? []
        for candidate in patchCandidates {
            let detailed = parseApplyPatchDetailed(candidate)
            if !detailed.files.isEmpty {
                return detailed.files.map { file in
                    let isMove = file.op == .move
                    let op: EditFileOp
                    switch file.op {
                    case .add: op = .add
                    case .update: op = .update
                    case .delete: op = .delete
                    case .move: op = .move
                    }
                    return EditFileChange(
                        path: isMove && !(file.to ?? "").isEmpty ? file.to! : file.path,
                        fromPath: isMove && !(file.from ?? "").isEmpty ? file.from : nil,
                        op: op,
                        additions: file.additions,
                        deletions: file.deletions,
                        lineRange: nil
                    )
                }
            }
        }

        if let parsed {
            let changes = extractEditChangesPayload(parsed, source: raw)
            if !changes.isEmpty {
                return changes.map { change in
                    if let diff = change.unifiedDiff, !JS.trim(diff).isEmpty {
                        return changeFromUnifiedDiff(change.path, unescapeInlineEscapes(diff))
                    }
                    let stats = LineChangeStats.estimateChangedLineStats(change.oldText, change.newText)
                    return EditFileChange(
                        path: change.path,
                        op: change.oldText.isEmpty ? .add : .update,
                        additions: stats.additions,
                        deletions: stats.deletions,
                        lineRange: nil
                    )
                }
            }

            let filePath = ActivityJSON.str(parsed, "file_path")
                ?? ActivityJSON.str(parsed, "path")
                ?? ActivityJSON.str(parsed, "notebook_path")
                ?? ActivityJSON.str(parsed, "filePath")
            if let filePath, !filePath.isEmpty {
                let outputDiff = output.flatMap { JS.test(hunkLineRE, $0) ? $0 : nil }
                if toolName == "write" {
                    let content = ActivityJSON.str(parsed, "content") ?? ActivityJSON.str(parsed, "new_source")
                    return [EditFileChange(path: filePath, op: .write,
                                           additions: content.map(ActivityFormat.countLines),
                                           deletions: nil, lineRange: nil)]
                }
                if toolName == "notebookedit" {
                    return [EditFileChange(path: filePath, op: .update, additions: nil, deletions: nil, lineRange: nil)]
                }
                if let outputDiff, !outputDiff.isEmpty {
                    var change = changeFromUnifiedDiff(filePath, outputDiff)
                    change.path = filePath
                    return [change]
                }
                let oldText = ActivityJSON.str(parsed, "old_string") ?? ActivityJSON.str(parsed, "old_text")
                let newText = ActivityJSON.str(parsed, "new_string") ?? ActivityJSON.str(parsed, "new_text")
                if oldText != nil || newText != nil {
                    let stats = LineChangeStats.estimateChangedLineStats(oldText ?? "", newText ?? "")
                    let startLine = ActivityJSON.num(parsed, "_start_line")
                    let multi = isTrue(parsed["replace_all"])
                    let range = startLine.flatMap { line in
                        multi ? nil : changedRangeFromReplacement(oldText ?? "", newText ?? "", startLine: line)
                    }
                    return [EditFileChange(path: filePath, op: .update,
                                           additions: stats.additions, deletions: stats.deletions,
                                           lineRange: range)]
                }
                let diffField = ActivityJSON.findStringFieldDeep(parsed, key: "unified_diff")
                    ?? ActivityJSON.findStringFieldDeep(parsed, key: "diff")
                if let diffField, looksLikeDiffPayload(diffField) {
                    var change = changeFromUnifiedDiff(filePath, unescapeInlineEscapes(diffField))
                    change.path = filePath
                    return [change]
                }
                return [EditFileChange(path: filePath, op: .update, additions: nil, deletions: nil, lineRange: nil)]
            }
        }

        // A bare unified diff as input (or, for an edit with no readable
        // input, as output): one entry per `+++` file.
        for candidate in [raw, output ?? ""] {
            if candidate.isEmpty || !looksLikeDiffPayload(candidate) { continue }
            let diff = unescapeInlineEscapes(candidate)
            let paths = unifiedDiffFiles(diff)
            if paths.count == 1 { return [changeFromUnifiedDiff(paths[0], diff)] }
            if paths.count > 1 {
                return paths.map { EditFileChange(path: $0, op: .update, additions: nil, deletions: nil, lineRange: nil) }
            }
        }
        return []
    }

    // MARK: - diff text for the detail panel

    private static let snippetHunkHeaderRE = JS.regex(
        lineStart + #"@@ -([0-9]+),([0-9]+) \+([0-9]+),([0-9]+) @@"#
    )

    /// Hunk headers of a diff generated from an `old_string → new_string`
    /// pair count from the snippet's first line; move them to where it sits
    /// in the file.
    private static func startLineAdjusted(_ diff: String, _ startLine: Double?) -> String {
        // `!startLine || startLine <= 1`.
        guard let startLine, startLine > 1 else { return diff }
        let n = NSRegularExpression.escapedTemplate(for: ActivityMcp.jsNumberString(startLine))
        return snippetHunkHeaderRE.stringByReplacingMatches(
            in: diff, range: NSRange(location: 0, length: (diff as NSString).length),
            withTemplate: "@@ -\(n),$2 +\(n),$4 @@"
        )
    }

    /// The unified diff (or `*** Begin Patch` text) an edit-like call's detail
    /// panel draws, from the first source that has one: a patch in the input,
    /// codex's changes map, a diff with real line numbers in the output, then a
    /// diff generated from the old/new strings. Write and notebook edits draw
    /// their new content as added lines.
    static func editDiffText(toolName: String, input: String?, output: String?) -> EditDiff? {
        let name = toolName.lowercased()
        let raw = input ?? ""
        let parsed = ToolNameNormalizer.aliasToolInputKeys(raw.isEmpty ? nil : ActivityJSON.tryParse(raw))

        if !raw.isEmpty, let patch = extractApplyPatchTextFromUnknownInput(raw, parsed), !patch.isEmpty {
            return EditDiff(text: patch, numbered: false)
        }
        if name == "apply_patch" {
            return JS.trim(raw).isEmpty ? nil : EditDiff(text: raw, numbered: JS.test(numberedHunkRE, raw))
        }

        if name == "write" || name == "notebookedit" {
            // OpenCode 2's write takes the file as `path`
            // (packages/core/src/tool/plugin/write.ts, 2.2.0).
            let path = parsed.flatMap {
                ActivityJSON.str($0, "file_path") ?? ActivityJSON.str($0, "notebook_path") ?? ActivityJSON.str($0, "path")
            }
            let content = parsed.flatMap { ActivityJSON.str($0, "content") ?? ActivityJSON.str($0, "new_source") }
            let diff = content.flatMap { $0.isEmpty ? nil : UnifiedDiffGenerator.generateUnifiedDiff("", $0, filePath: path) }
            // A whole new file starts at line 1, so its numbers are real; a
            // notebook cell's are not.
            return diff.map { EditDiff(text: $0, numbered: name == "write", noBefore: true) }
        }

        if let parsed {
            let changes = extractEditChangesPayload(parsed, source: raw)
            if !changes.isEmpty {
                var parts: [String] = []
                var numbered = true
                for change in changes {
                    if let diff = change.unifiedDiff, !JS.trim(diff).isEmpty {
                        parts.append(contentsOf: [JS.trim(diff), ""])
                        if !JS.test(numberedHunkRE, diff) { numbered = false }
                        continue
                    }
                    if let generated = UnifiedDiffGenerator.generateUnifiedDiff(
                        change.oldText, change.newText, filePath: change.path) {
                        parts.append(contentsOf: [generated, ""])
                        // A new file's lines are numbered from 1 for real.
                        if !change.oldText.isEmpty { numbered = false }
                    }
                }
                let joined = JS.trim(parts.joined(separator: "\n"))
                if !joined.isEmpty { return EditDiff(text: joined, numbered: numbered) }
            }
        }

        if let output, JS.test(hunkLineRE, output) {
            return EditDiff(text: output, numbered: JS.test(numberedHunkRE, output))
        }

        if let parsed, isCanonicalEditPayload(parsed) {
            guard let diff = UnifiedDiffGenerator.generateUnifiedDiff(
                ActivityJSON.str(parsed, "old_string") ?? "",
                ActivityJSON.str(parsed, "new_string") ?? "",
                filePath: ActivityJSON.str(parsed, "file_path") ?? ActivityJSON.str(parsed, "path")
            ) else { return nil }
            let startLine = ActivityJSON.num(parsed, "_start_line")
            return EditDiff(text: startLineAdjusted(diff, startLine), numbered: (startLine ?? 0) > 0)
        }

        if !raw.isEmpty, looksLikeDiffPayload(raw) {
            let text = unescapeInlineEscapes(raw)
            return EditDiff(text: text, numbered: JS.test(numberedHunkRE, text))
        }
        return nil
    }

    // MARK: - JavaScript object key order

    private static func asciiLowercased(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { scalar in
            ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }))
    }

    /// `obj`'s keys in the order JavaScript's `Object.keys` yields them:
    /// array-index keys ascending, then the rest in insertion order.
    /// `JSONSerialization` keeps no order, so it is recovered from `source`,
    /// the text `obj` was parsed from (directly or through a JSON string nested
    /// in it): the first object there with exactly `obj`'s keys supplies the
    /// order. Falls back to sorted keys when none matches.
    private static func jsObjectKeys(_ obj: [String: Any], source: String) -> [String] {
        let wanted = Set(obj.keys)
        var ordered = obj.keys.sorted()
        if wanted.count > 1 {
            for list in objectKeyLists(source, depth: 0) {
                var seen = Set<String>()
                let unique = list.filter { seen.insert($0).inserted }
                if unique.count == wanted.count, Set(unique) == wanted {
                    ordered = unique
                    break
                }
            }
        }
        let indexKeys = ordered.compactMap { key in arrayIndex(key).map { ($0, key) } }
            .sorted { $0.0 < $1.0 }.map(\.1)
        return indexKeys + ordered.filter { arrayIndex($0) == nil }
    }

    /// A canonical array index (`"0"`, `"12"`, below 2³²−1), which JavaScript
    /// enumerates before string keys.
    private static func arrayIndex(_ key: String) -> UInt32? {
        guard !key.isEmpty, key.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              key == "0" || !key.hasPrefix("0"),
              let value = UInt32(key), value < UInt32.max else { return nil }
        return value
    }

    /// The key list of every object in a JSON text, in the order the objects
    /// open, each list in source order with keys decoded. String values that
    /// hold a JSON object (what ``ActivityJSON/asObjectLike(_:)`` would parse)
    /// are scanned too.
    private static func objectKeyLists(_ source: String, depth: Int) -> [[String]] {
        if depth > 5 { return [] }
        let units = Array(source.utf16)
        let quote: UInt16 = 0x22, backslash: UInt16 = 0x5C
        var lists: [[String]] = []
        // Per open container: its list index (-1 for an array) and whether the
        // next string is a key.
        var stack: [(list: Int, expectKey: Bool)] = []
        var i = 0
        while i < units.count {
            let c = units[i]
            if c == quote {
                let start = i + 1
                i = start
                while i < units.count, units[i] != quote {
                    i += units[i] == backslash ? 2 : 1
                }
                let end = min(i, units.count)
                let literal = [quote] + units[start..<end] + [quote]
                let decoded = ActivityJSON.parseValue(String(decoding: literal, as: UTF16.self)) as? String
                if let top = stack.last, top.list >= 0, top.expectKey {
                    if let decoded { lists[top.list].append(decoded) }
                    stack[stack.count - 1].expectKey = false
                } else if let decoded, JS.startsWith(JS.trim(decoded), "{") {
                    lists.append(contentsOf: objectKeyLists(decoded, depth: depth + 1))
                }
                i += 1
                continue
            }
            switch c {
            case 0x7B: // {
                lists.append([])
                stack.append((lists.count - 1, true))
            case 0x5B: // [
                stack.append((-1, false))
            case 0x7D, 0x5D: // } ]
                if !stack.isEmpty { stack.removeLast() }
            case 0x2C: // ,
                if let top = stack.last, top.list >= 0 { stack[stack.count - 1].expectKey = true }
            default:
                break
            }
            i += 1
        }
        return lists
    }
}
