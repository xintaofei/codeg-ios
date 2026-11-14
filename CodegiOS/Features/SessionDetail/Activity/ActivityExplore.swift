import Foundation

/// Read and search results, reduced to what an activity row reports about
/// them: the file text a read returned (and how many lines it was), and how
/// many hits a search found — port of the web's `src/lib/activity/explore.ts`
/// (codeg 0.44).
enum ActivityExplore {
    private typealias JS = ActivityCommand.JS

    /// codex classifies file-reading shell commands (sed/cat/head) as ACP
    /// `read` commandActions whose output is a command-execution envelope —
    /// codex-acp's `createCommandExecutionCompleteUpdate` always sends BOTH
    /// `{formatted_output: <string>, exit_code: <number>}` — NOT the
    /// `{start_line, content}` read shape. Returns the inner `formatted_output`
    /// so the file content renders. Requiring BOTH keys keeps a genuine
    /// JSON-file read (`{output: …}`, `{stdout: …}`, a lone `{exit_code: 0}`,
    /// …) from being mistaken for a command envelope. Nil when it isn't that
    /// exact shape.
    ///
    /// Read-only on purpose: the sibling search body unwraps the envelope
    /// WITHOUT the CLI-framing strip below, because a search's matched line can
    /// legitimately begin with one of those metadata words.
    static func codexCommandReadOutput(_ raw: String) -> String? {
        guard let envelope = CodexCommandEnvelope.parse(raw) else { return nil }
        let out = envelope.output
        // Strip codex's CLI framing ("Chunk ID:/Wall time:/…/Output:\n<content>")
        // only when the output actually STARTS with that metadata — so a clean
        // file whose first line happens to be "Output:" is never truncated by
        // the envelope parser.
        let firstLine = JS.trim(JS.split(out, "\n").first { !JS.trim($0).isEmpty } ?? "")
        return ActivityCommand.isCliMetaLine(firstLine)
            ? ActivityCommand.parseCliExecutionEnvelope(out).output
            : out
    }

    /// A read's file text and the line it starts at.
    struct ReadOutput: Equatable, Sendable {
        var startLine: Int
        var content: String
    }

    /// Parse structured read output from the backend:
    /// `{"start_line":N,"content":"..."}`. Falls back to codex's command
    /// envelope, then to the raw text, with `startLine` 1.
    static func parseReadOutput(_ raw: String) -> ReadOutput {
        if let obj = ActivityJSON.parseValue(raw) as? [String: Any],
           let start = ActivityJSON.number(obj["start_line"]),
           let content = obj["content"] as? String {
            return ReadOutput(startLine: lineNumber(start), content: content)
        }
        if let commandOutput = codexCommandReadOutput(raw) {
            return ReadOutput(startLine: 1, content: commandOutput)
        }
        return ReadOutput(startLine: 1, content: raw)
    }

    /// The web accepts any JSON number as `start_line`; a line number here is
    /// an `Int`, so a fractional one is truncated.
    private static func lineNumber(_ value: Double) -> Int {
        guard value.isFinite, value.magnitude < Double(Int.max) else { return 1 }
        return Int(value)
    }

    /// How many lines a successful read returned, or nil when nothing came
    /// back.
    static func readLineCount(_ output: String?) -> Int? {
        guard let output, !output.isEmpty else { return nil }
        let lines = ActivityFormat.countLines(parseReadOutput(output).content)
        return lines > 0 ? lines : nil
    }

    /// True for the one command envelope that means "the search ran fine and
    /// matched nothing": codex derives an ACP tool status from the process
    /// exit code, and rg/grep exit 1 when no line was selected, so a healthy
    /// negative search arrives as a FAILED tool call carrying `{exit_code: 1,
    /// formatted_output: ""}`. Callers must first establish that the tool is a
    /// grep-like search: for list-files commands exit 1 is a genuine failure.
    /// Whitespace-only output counts as empty. Port of web
    /// `isCodexGrepNoMatchEnvelope` (`codex-command-action.ts`).
    static func isCodexGrepNoMatchEnvelope(_ raw: String) -> Bool {
        guard let envelope = CodexCommandEnvelope.parse(raw) else { return false }
        return envelope.exitCode == 1 && JS.trim(envelope.output).isEmpty
    }

    /// The text a search printed, with codex's command envelope unwrapped and
    /// nothing else touched: a search prints the files' own lines, which can
    /// read like CLI framing (`Wall time:`, `Output:`) or be the code fences it
    /// was looking for, so the command-output cleanup would delete real
    /// matches. `""` is a real result (no matches); nil means there is no
    /// result to read yet.
    static func searchResultText(toolName: String, output: String?, errorText: String?) -> String? {
        if let errorText {
            if toolName != "grep" { return nil }
            return isCodexGrepNoMatchEnvelope(errorText) ? "" : nil
        }
        guard let output else { return nil }
        return CodexCommandEnvelope.parse(output)?.output ?? output
    }

    /// What a search found (web `SearchOutcome`).
    enum SearchOutcome: Equatable, Hashable, Sendable {
        case none
        case matches(matches: Int, files: Int)
        case files(files: Int)
        case lines(lines: Int)
    }

    private static let foundPreambleRE = JS.regex(
        #"^Found [0-9]+ (?:files?|matches?|results?)(?![A-Za-z0-9_])[^\n]*\n?"#, ignoreCase: true)
    private static let noResultsRE = JS.regex(#"^No (?:files|matches|results) found\.?\z"#, ignoreCase: true)

    /// What a search found, in the unit its output is in: matched lines (grep
    /// with line numbers), file paths (glob, `rg --files`, `ls`), or — when the
    /// output is in neither shape — plain result lines.
    static func summarizeSearchResult(_ text: String?) -> SearchOutcome? {
        guard let text else { return nil }
        // Claude Code's Grep/Glob say "No files found" / "No matches found" for
        // an empty result, and open a files-with-matches listing with "Found N
        // files".
        let body = JS.trim(JS.replaceFirst(foundPreambleRE, in: JS.trim(text)))
        if body.isEmpty || JS.test(noResultsRE, body) { return SearchOutcome.none }
        switch searchShape(body) {
        case let .matches(matches, files)?: return .matches(matches: matches, files: files)
        case let .files(files)?: return .files(files: files)
        case nil:
            let lines = ActivityFormat.countLines(body)
            return lines > 0 ? .lines(lines: lines) : SearchOutcome.none
        }
    }

    // MARK: - Search output shape

    private enum SearchShape {
        case matches(matchCount: Int, fileCount: Int)
        case files(fileCount: Int)
    }

    /// `<path>:<line>:<content>`, path lazy so a Windows drive letter still
    /// parses.
    private static let matchLineRE = JS.regex(#"^(\#(JS.dot)*?):([0-9]+):([\s\S]*)\z"#)
    /// ripgrep's context separator between non-adjacent hunks.
    private static let contextSeparatorRE = JS.regex(#"^--+\z"#)
    /// Trailing extension, used to accept extension-only names from `ls`.
    private static let fileExtensionRE = JS.regex(#"\.[A-Za-z0-9_+\-]+\z"#)
    private static let numericRE = JS.regex(#"^[0-9.]+\z"#)
    private static let pathCharRE = JS.regex(#"[./\\]"#)
    private static let separatorRE = JS.regex(#"[/\\]"#)
    private static let whitespaceRE = JS.regex(JS.s)
    private static let crlfRE = JS.regex(#"\r\n?"#)

    /// The counts web `parseSearchOutput` (`search-output.ts`) reports, with
    /// `maxRows` unbounded — `capRows` never changes them. Not
    /// `SearchOutputParse.parse`: that one scans at most 4 000 lines, splits on
    /// `Character`s (so a `\r\n` line is never split), and skips a lone `-` as
    /// a context separator, each of which changes a count here.
    ///
    /// Recognition is deliberately conservative: unless (nearly) every line
    /// fits one shape this is nil and the caller falls back to plain lines.
    private static func searchShape(_ text: String) -> SearchShape? {
        if JS.trim(text).isEmpty { return nil }
        let normalized = crlfRE.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "\n")

        // Paths keyed by UTF-16 code units, as a JavaScript `Map` keys them
        // (a Swift `String` key would merge canonically equivalent paths).
        var matchPaths = Set<[UInt16]>()
        var matchLineCount = 0
        var filePathCount = 0
        var considered = 0

        for raw in JS.split(normalized, "\n") {
            let line = JS.trimEnd(raw)
            let trimmed = JS.trim(line)
            if trimmed.isEmpty { continue }
            if JS.test(contextSeparatorRE, trimmed) { continue }
            considered += 1

            if let match = JS.match(matchLineRE, line), let path = match[1], looksLikeMatchPath(path) {
                matchPaths.insert(Array(path.utf16))
                matchLineCount += 1
                continue
            }
            if looksLikeBarePath(trimmed) { filePathCount += 1 }
        }

        if considered == 0 { return nil }
        let threshold = Int((Double(considered) * 0.8).rounded(.up))
        if matchLineCount > 0, matchLineCount >= threshold {
            return .matches(matchCount: matchLineCount, fileCount: matchPaths.count)
        }
        if filePathCount > 0, filePathCount >= threshold {
            return .files(fileCount: filePathCount)
        }
        return nil
    }

    /// A path in `<path>:<line>:<content>` must look like a filesystem path,
    /// not a number — otherwise timestamps (`12:34:56 done`) and `line:col`
    /// diagnostics parse as matches. Spaces are allowed: the `:<digits>:`
    /// anchor is specific enough, and paths with spaces are real.
    private static func looksLikeMatchPath(_ value: String) -> Bool {
        if value.isEmpty { return false }
        if !JS.test(pathCharRE, value) { return false }
        return !JS.test(numericRE, value)
    }

    /// A bare path line. Stricter than `looksLikeMatchPath` — with no
    /// `:<line>:` anchor, whitespace is the only thing separating a path from
    /// prose like "(Results are truncated, consider using a more specific
    /// path.)". The two exclusions cover the shapes that otherwise sneak past
    /// the extension rule: version-like tokens (`1.2.3`) and JSON records
    /// (`rg --json`), neither of which is a file to link to.
    private static func looksLikeBarePath(_ value: String) -> Bool {
        if value.isEmpty || JS.test(whitespaceRE, value) { return false }
        if JS.test(numericRE, value) { return false }
        if JS.startsWith(value, "{") || JS.startsWith(value, "[") { return false }
        return JS.test(separatorRE, value) || JS.test(fileExtensionRE, value)
    }
}
