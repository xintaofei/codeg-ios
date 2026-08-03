import SwiftUI

/// Parse the stdout of a search tool (ripgrep / grep / Glob / codex's `search`
/// and `listFiles` command actions) into a structure the card can show as
/// grouped results instead of a wall of text.
///
/// Two recognised shapes:
///   - `matches`: `<path>:<line>:<content>` — grep/rg with line numbers
///   - `files`:   one bare path per line    — `rg --files`, Glob, `ls`
///
/// Recognition is deliberately conservative: unless (nearly) every line fits one
/// shape the parse fails and the caller falls back to plain text. Search output
/// is agent- and flag-dependent (`rg -c` counts, `--heading` groups, ANSI
/// colours, "Found N files" preambles), and a half-parsed result reads far worse
/// than the raw text.
///
/// Ports web `lib/search-output.ts`.
enum SearchOutputParse {

    struct MatchLine {
        /// 1-based line number in the owning path; nil in `files` mode.
        let line: Int?
        let text: String
    }

    struct FileGroup: Identifiable {
        let path: String
        /// Empty in `files` mode.
        let lines: [MatchLine]
        var id: String { path }
    }

    enum Mode { case matches, files }

    struct Result {
        let mode: Mode
        let groups: [FileGroup]
        /// Total matched lines across all files (0 in `files` mode).
        let matchCount: Int
        let fileCount: Int
        /// Rows dropped by `maxRows`; 0 when everything is shown.
        let hiddenCount: Int
        /// Lines that fit neither shape (rg warnings, "Found N files", …).
        let notes: [String]
        /// True when the output ran past `maxLines` and the rest was not read.
        let truncated: Bool
    }

    /// Minimum share of considered lines that must fit a shape to accept it.
    private static let minParseRatio = 0.8
    private static let defaultMaxRows = 200
    /// Lines actually examined. The web parses the whole output; here the parse
    /// re-runs inside a view body, and a broad `rg` can return tens of thousands
    /// of lines — so the scan is bounded and the fact that it was is REPORTED
    /// (`truncated`) rather than silently dropped.
    static let defaultMaxLines = 4_000

    static func parse(_ text: String,
                      maxRows: Int = defaultMaxRows,
                      maxLines: Int = defaultMaxLines) -> Result? {
        guard !text.isEmpty else { return nil }

        // `maxSplits` STOPS the scan at the budget — the tail past it becomes
        // one trailing Substring that is never walked. Splitting the whole
        // string first (or normalizing line endings across it) would be
        // O(entire output) on every body evaluation no matter what the cap said.
        // `\r\n` is handled per line by `trimmingTrailingWhitespace` below.
        var lines = text.split(separator: "\n", maxSplits: maxLines, omittingEmptySubsequences: false)
        var truncated = false
        if lines.count > maxLines {
            // The split hit its budget, so the final element is the unread tail.
            lines.removeLast()
            truncated = true
        }

        // Insertion order matters (results read top-down), so keep the paths in
        // a parallel array rather than relying on Dictionary ordering.
        var matchOrder: [String] = []
        var matchGroups: [String: [MatchLine]] = [:]
        var filePaths: [String] = []
        var notes: [String] = []
        var considered = 0
        var matchLineCount = 0

        for raw in lines {
            let line = String(raw).trimmingTrailingWhitespace()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // ripgrep's separator between non-adjacent context hunks.
            if trimmed.allSatisfy({ $0 == "-" }) { continue }
            considered += 1

            if let hit = splitMatchLine(line), looksLikeMatchPath(hit.path) {
                let entry = MatchLine(line: hit.line, text: hit.text)
                if matchGroups[hit.path] == nil {
                    matchOrder.append(hit.path)
                    matchGroups[hit.path] = [entry]
                } else {
                    matchGroups[hit.path]?.append(entry)
                }
                matchLineCount += 1
                continue
            }

            if looksLikeBarePath(trimmed) {
                filePaths.append(trimmed)
                continue
            }

            notes.append(trimmed)
        }

        guard considered > 0 else { return nil }
        let threshold = Int((Double(considered) * minParseRatio).rounded(.up))

        if matchLineCount > 0, matchLineCount >= threshold {
            let groups = matchOrder.map { FileGroup(path: $0, lines: matchGroups[$0] ?? []) }
            return capRows(Result(mode: .matches, groups: groups,
                                  matchCount: matchLineCount, fileCount: groups.count,
                                  hiddenCount: 0, notes: notes,
                                  truncated: truncated), maxRows: maxRows)
        }

        if !filePaths.isEmpty, filePaths.count >= threshold {
            return capRows(Result(mode: .files,
                                  groups: filePaths.map { FileGroup(path: $0, lines: []) },
                                  matchCount: 0, fileCount: filePaths.count,
                                  hiddenCount: 0, notes: notes,
                                  truncated: truncated), maxRows: maxRows)
        }

        return nil
    }

    /// `<path>:<line>:<content>` with a LAZY path — the first `:` followed by
    /// digits and another `:`. Hand-scanned rather than regexed so a Windows
    /// drive letter (`C:\src\a.rs:12:…`) still parses and so the per-line cost
    /// stays linear.
    private static func splitMatchLine(_ line: String) -> (path: String, line: Int, text: String)? {
        var index = line.startIndex
        while let colon = line[index...].firstIndex(of: ":") {
            var digits = line.index(after: colon)
            while digits < line.endIndex, line[digits].isASCIIDigit { digits = line.index(after: digits) }
            if digits > line.index(after: colon), digits < line.endIndex, line[digits] == ":",
               let number = Int(line[line.index(after: colon)..<digits]) {
                return (String(line[line.startIndex..<colon]),
                        number,
                        String(line[line.index(after: digits)...]))
            }
            guard colon < line.endIndex else { return nil }
            index = line.index(after: colon)
        }
        return nil
    }

    /// A path in `<path>:<line>:<content>` must look like a filesystem path, not
    /// a number — otherwise timestamps (`12:34:56 done`) and `line:col`
    /// diagnostics parse as matches. Spaces are allowed: the `:<digits>:` anchor
    /// is specific enough, and paths with spaces are real.
    private static func looksLikeMatchPath(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard value.contains(where: { $0 == "." || $0 == "/" || $0 == "\\" }) else { return false }
        return !value.allSatisfy { $0.isASCIIDigit || $0 == "." }
    }

    /// A bare path line. Stricter than `looksLikeMatchPath` — with no `:<line>:`
    /// anchor, whitespace is the only thing separating a path from prose like
    /// "(Results are truncated, consider using a more specific path.)". The two
    /// exclusions cover the shapes that otherwise sneak past the extension rule:
    /// version-like tokens (`rg -o '\d+\.\d+\.\d+'` → `1.2.3`) and JSON records
    /// (`rg --json`), neither of which is a file.
    private static func looksLikeBarePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return false }
        if value.allSatisfy({ $0.isASCIIDigit || $0 == "." }) { return false }
        if value.hasPrefix("{") || value.hasPrefix("[") { return false }
        if value.contains("/") || value.contains("\\") { return true }
        return hasFileExtension(value)
    }

    /// A trailing `.<alnum/_/+/->` extension, used to accept extension-only
    /// names from `ls`.
    private static func hasFileExtension(_ value: String) -> Bool {
        guard let dot = value.lastIndex(of: ".") else { return false }
        let ext = value[value.index(after: dot)...]
        guard !ext.isEmpty else { return false }
        return ext.allSatisfy { $0.isASCIIDigit || $0.isASCIILetter || $0 == "_" || $0 == "+" || $0 == "-" }
    }

    /// Trim the result set to `maxRows` renderable rows — matched lines in
    /// `matches` mode, files in `files` mode — recording the remainder in
    /// `hiddenCount`. The counts stay authoritative (they describe the full
    /// output, not the shown part).
    private static func capRows(_ parsed: Result, maxRows: Int) -> Result {
        guard maxRows > 0 else { return parsed }

        if parsed.mode == .files {
            guard parsed.groups.count > maxRows else { return parsed }
            return Result(mode: .files, groups: Array(parsed.groups.prefix(maxRows)),
                          matchCount: 0, fileCount: parsed.fileCount,
                          hiddenCount: parsed.groups.count - maxRows, notes: parsed.notes,
                          truncated: parsed.truncated)
        }

        guard parsed.matchCount > maxRows else { return parsed }
        var groups: [FileGroup] = []
        var shown = 0
        for group in parsed.groups {
            if shown >= maxRows { break }
            let lines = Array(group.lines.prefix(maxRows - shown))
            shown += lines.count
            groups.append(FileGroup(path: group.path, lines: lines))
        }
        return Result(mode: .matches, groups: groups, matchCount: parsed.matchCount,
                      fileCount: parsed.fileCount, hiddenCount: parsed.matchCount - shown,
                      notes: parsed.notes, truncated: parsed.truncated)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}

// MARK: - View

/// Result body for search-shaped tool calls (Grep / Glob, and codex's `search` /
/// `listFiles` command actions): the stdout grouped per file with line numbers,
/// falling back to the plain code block the generic output renderer would have
/// produced for anything the parser can't confidently recognise.
///
/// Mirrors web `search-results-output.tsx`. Paths are plain text rather than
/// links: unlike the desktop app, the transcript has nowhere to open a file.
struct SearchResultsView: View {
    let text: String
    /// Search pattern, highlighted in each matched line where it occurs
    /// literally. The pattern is a regex on the agent's side, so a literal
    /// search is deliberately the only thing tried — a regex query simply
    /// renders unhighlighted rather than lighting up the wrong characters.
    var query: String?

    /// Same height cap as the file-read viewer: a broad search can match
    /// hundreds of lines, and an unbounded card pushes the rest of the
    /// transcript off screen.
    private static let maxHeight: CGFloat = 340

    var body: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Empty stdout from a search means "no matches" (rg/grep exit 1),
            // which the raw envelope rendered as `{"exit_code":1,…}`.
            Label("No matches", systemImage: "magnifyingglass")
                .font(Theme.Typography.metaLabel)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        } else if let parsed = SearchOutputParse.parse(text) {
            results(parsed)
        } else {
            CodeBlockView(code: text, language: "output")
        }
    }

    private func results(_ parsed: SearchOutputParse.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            summary(parsed)
                .font(Theme.Typography.metaLabel)
                .foregroundStyle(Theme.textTertiary)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(parsed.groups) { group in
                        groupView(group, mode: parsed.mode)
                    }
                }
            }
            .frame(maxHeight: Self.maxHeight)
            .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .hairlineBorder(Theme.Radius.sm, color: Theme.hairline)

            if parsed.hiddenCount > 0 {
                Text("\(parsed.hiddenCount) more not shown")
                    .font(Theme.Typography.metaLabel)
                    .foregroundStyle(Theme.textTertiary)
            }
            if parsed.truncated {
                Text("Only the first \(SearchOutputParse.defaultMaxLines) lines were scanned")
                    .font(Theme.Typography.metaLabel)
                    .foregroundStyle(Theme.textTertiary)
            }
            if !parsed.notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(parsed.notes.prefix(8).enumerated()), id: \.offset) { _, note in
                        Text(verbatim: note)
                            .font(.mono(10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
        }
    }

    /// `inflect:` lets the catalog agree the nouns with their counts without a
    /// key per plural form; languages without plural agreement just translate
    /// the phrase.
    private func summary(_ parsed: SearchOutputParse.Result) -> Text {
        switch parsed.mode {
        case .matches:
            return Text("^[\(parsed.matchCount) match](inflect: true) in ^[\(parsed.fileCount) file](inflect: true)")
        case .files:
            return Text("^[\(parsed.fileCount) file](inflect: true)")
        }
    }

    @ViewBuilder
    private func groupView(_ group: SearchOutputParse.FileGroup,
                           mode: SearchOutputParse.Mode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
                Text(verbatim: group.path)
                    .font(.mono(10.5))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if group.lines.count > 1 {
                    Text(verbatim: "\(group.lines.count)")
                        .font(Theme.Typography.metaLabel.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(mode == .matches ? 0.04 : 0))

            ForEach(Array(group.lines.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: entry.line.map(String.init) ?? "")
                        .font(.mono(10.5).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 34, alignment: .trailing)
                    Text(highlighted(entry.text))
                        .font(.mono(10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8).padding(.vertical, 2)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    /// Highlight literal occurrences of `query` in one matched line.
    ///
    /// Capped at `maxHighlights` runs: a short query (agents do write `rg "e"`)
    /// against a long or minified line would otherwise produce one attributed
    /// run per occurrence — enough to stall layout when the card is expanded.
    /// Past the cap the rest of the line renders plain.
    private static let maxHighlights = 100

    private func highlighted(_ line: String) -> AttributedString {
        // Leading indentation is dropped so matches line up (the web does the
        // same); the line number gutter already carries the structure.
        let text = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines),
              !needle.isEmpty, needle.count <= 200,
              text.range(of: needle, options: .caseInsensitive) != nil
        else { return AttributedString(text) }

        var out = AttributedString()
        var cursor = text.startIndex
        var runs = 0
        while runs < Self.maxHighlights,
              let hit = text.range(of: needle, options: .caseInsensitive, range: cursor..<text.endIndex) {
            if hit.lowerBound > cursor { out += AttributedString(text[cursor..<hit.lowerBound]) }
            var mark = AttributedString(text[hit])
            mark.backgroundColor = Theme.warning.opacity(0.28)
            mark.foregroundColor = Theme.textPrimary
            out += mark
            cursor = hit.upperBound
            runs += 1
        }
        if cursor < text.endIndex { out += AttributedString(text[cursor...]) }
        return out
    }
}
