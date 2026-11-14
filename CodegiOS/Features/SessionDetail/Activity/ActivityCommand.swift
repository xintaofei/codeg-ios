import Foundation

/// Shell-command display and output normalization, shared by the command step
/// descriptor and the command row/card bodies — port of the web's
/// `src/lib/activity/command.ts` (codeg 0.44).
///
/// Agents wrap commands (`/bin/zsh -lc 'bash -lc "<cmd>"'`), hand them over as
/// strings, argv arrays or nested `{command}` objects, and return output inside
/// JSON envelopes or codex's text framing. Everything here reduces those shapes
/// to the command a person typed and the text the process printed.
enum ActivityCommand {

    // MARK: - Command display

    private static func unwrapQuotedCommand(_ command: String) -> String {
        let trimmed = JS.trim(command)
        if trimmed.utf16.count < 2 { return trimmed }

        if JS.startsWith(trimmed, "'"), JS.endsWith(trimmed, "'") {
            return JS.sliceScalars(trimmed, dropFirst: 1, dropLast: 1)
        }

        if JS.startsWith(trimmed, "\""), JS.endsWith(trimmed, "\"") {
            return JS.sliceScalars(trimmed, dropFirst: 1, dropLast: 1)
                .replacingOccurrences(of: "\\\"", with: "\"", options: .literal)
                .replacingOccurrences(of: "\\n", with: "\n", options: .literal)
                .replacingOccurrences(of: "\\\\", with: "\\", options: .literal)
        }

        return trimmed
    }

    private static let wrapperRE = JS.regex(
        #"^(?:/usr/bin/env\#(JS.s)+)?(?:(?:/\#(JS.S)+/)?(?:bash|zsh|sh))\#(JS.s)+-(?:l?c)\#(JS.s)+(\#(JS.dot)+)\z"#,
        ignoreCase: true)

    /// Strip nested shell wrappers like `/bin/zsh -lc bash -lc '<cmd>'`.
    static func simplifyShellCommand(_ command: String) -> String {
        var current = JS.trim(command)
        for _ in 0..<6 {
            guard let wrapped = JS.match(wrapperRE, current) else { break }
            let next = JS.trim(unwrapQuotedCommand(wrapped[1] ?? ""))
            if next.isEmpty || next == current { break }
            current = next
        }
        return current
    }

    /// The command in a tool input that may be a JSON string, argv array,
    /// `{command|cmd|script}` object, or plain command text. Nil for JSON-looking
    /// text that holds no command.
    static func extractCommandFromUnknownInput(_ input: String) -> String? {
        let trimmed = JS.trim(input)
        if trimmed.isEmpty { return nil }

        if let parsed = ActivityJSON.parseValue(trimmed) {
            if let s = parsed as? String { return s }
            if let array = parsed as? [Any] {
                let parts = array.compactMap { $0 as? String }
                if !parts.isEmpty { return parts.joined(separator: " ") }
            }
            if let obj = parsed as? [String: Any] {
                // `obj.command ?? obj.cmd ?? obj.script`: `??` only skips a
                // missing key or a JSON null.
                let direct = ["command", "cmd", "script"].lazy
                    .compactMap { obj[$0] }
                    .first { !($0 is NSNull) }
                if let s = direct as? String { return s }
                if let array = direct as? [Any] {
                    let parts = array.compactMap { $0 as? String }
                    if !parts.isEmpty { return parts.joined(separator: " ") }
                }
            }
        }

        if JS.startsWith(trimmed, "{") || JS.startsWith(trimmed, "[") { return nil }
        return trimmed
    }

    private static let directCommandKeys = [
        "command",
        "cmd",
        "script",
        // Antigravity's terminal arguments — `command_line` on the executed
        // call, PascalCase `CommandLine` on the model's own envelope (the shape
        // a permission-prompt frame and the stored trajectory both carry).
        // Ahead of the argv-style keys so an envelope that has both keeps the
        // full command line.
        "command_line",
        "CommandLine",
        "args",
        "argv",
        "command_args",
    ]
    private static let nestedCommandKeys = ["input", "arguments", "params", "payload"]

    /// A command out of a parsed JSON value: a non-blank string, the non-empty
    /// strings of an argv array, or the first such value under a command key —
    /// directly, then one envelope down.
    static func commandFromUnknownValue(_ value: Any?) -> String? {
        if let s = value as? String {
            let trimmed = JS.trim(s)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let array = value as? [Any] {
            let parts = array.compactMap { $0 as? String }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        guard let obj = value as? [String: Any] else { return nil }
        for key in directCommandKeys {
            if let found = commandFromUnknownValue(obj[key]) { return found }
        }
        for key in nestedCommandKeys {
            if let found = commandFromUnknownValue(obj[key]) { return found }
        }
        return nil
    }

    /// The command a tool input ran, its shell wrappers stripped, for display.
    static func extractDisplayCommandFromToolInput(_ input: String?) -> String? {
        guard let input, !input.isEmpty else { return nil }
        let parsed = ActivityJSON.tryParse(input)
        let command = (parsed.flatMap { commandFromUnknownValue($0) })
            ?? extractCommandFromUnknownInput(input)
        guard let command else { return nil }
        let simplified = JS.trim(simplifyShellCommand(command))
        return simplified.isEmpty ? nil : simplified
    }

    // MARK: - Command output

    /// The printed text of a JSON command-result envelope — raw `stdout` /
    /// `stderr` first (more likely to preserve ANSI colours), then
    /// `formatted_output`, `aggregated_output`, `output`, `text`, `result`.
    /// `""` for a metadata-only envelope (command/cwd/exit_code), so raw JSON
    /// is never rendered as terminal output; nil when it is no such envelope.
    ///
    /// Reuses `ToolOutputFormat.commandOutput(fromJSON:)`, which ports the same
    /// web function rule for rule.
    static func commandOutputFromJsonString(_ output: String) -> String? {
        ToolOutputFormat.commandOutput(fromJSON: output)
    }

    private static let fenceOpenRE = JS.regex(#"^\#(JS.s)*```[A-Za-z0-9_\-]*\#(JS.s)*\n?"#)
    private static let fenceCloseRE = JS.regex(#"\n?\#(JS.s)*```\#(JS.s)*\z"#)

    /// Remove a leading fenced-code line (```` ```sh ````, ```` ``` ````) and a
    /// trailing closing fence.
    static func stripMarkdownCodeFence(_ text: String) -> String {
        JS.replaceFirst(fenceCloseRE, in: JS.replaceFirst(fenceOpenRE, in: text))
    }

    /// Matches metadata lines in CLI execution output envelopes (web
    /// `CLI_META_LINE_RE`).
    static let cliMetaLineRE = JS.regex(
        #"^(exit code\#(JS.s)*[:=]|wall time\#(JS.s)*[:=]|chunk id\#(JS.s)*[:=]|original token count\#(JS.s)*[:=]|total output lines\#(JS.s)*[:=]|process exited with code\#(JS.s))"#,
        ignoreCase: true)

    static func isCliMetaLine(_ line: String) -> Bool {
        JS.test(cliMetaLineRE, line)
    }

    private static let wallTimeLineRE = JS.regex(#"^wall time\#(JS.s)*:\#(JS.s)*(\#(JS.dot)+)"#, ignoreCase: true)
    private static let outputSeparatorRE = JS.regex(#"^output:\#(JS.s)*\z"#, ignoreCase: true)

    /// A CLI execution envelope's command output and its wall time.
    struct CliExecutionEnvelope: Equatable, Sendable {
        var output: String
        var wallTime: String?
    }

    /// Parse a CLI execution envelope, stripping all metadata and the `Output:`
    /// separator, returning only the actual command output and the wall time.
    ///
    /// Handles formats like:
    ///
    ///     Chunk ID: 065b2b
    ///     Wall time: 0.05s
    ///     Process exited with code 0
    ///     Original token count: 27006
    ///     Output:
    ///     Total output lines: 1134
    ///     <actual output here>
    static func parseCliExecutionEnvelope(_ text: String) -> CliExecutionEnvelope {
        let lines = JS.split(text, "\n")
        var wallTime: String?

        // Look for the "Output:" separator and pick the wall time out of the
        // header on the way.
        var outputSepIndex = -1
        for (i, line) in lines.enumerated() {
            let trimmed = JS.trim(line)
            if let wt = JS.match(wallTimeLineRE, trimmed), let value = wt[1] { wallTime = JS.trim(value) }
            if JS.test(outputSeparatorRE, trimmed) {
                outputSepIndex = i
                break
            }
            // Stop scanning at a non-metadata, non-blank line (actual content).
            if !isCliMetaLine(trimmed), !trimmed.isEmpty { break }
        }

        // With a separator, skip everything before it plus any remaining
        // metadata / blank lines after it.
        if outputSepIndex >= 0 {
            var start = outputSepIndex + 1
            while start < lines.count {
                let trimmed = JS.trim(lines[start])
                if isCliMetaLine(trimmed) || trimmed.isEmpty {
                    start += 1
                    continue
                }
                break
            }
            return CliExecutionEnvelope(output: lines[start...].joined(separator: "\n"), wallTime: wallTime)
        }

        // No separator — strip leading metadata lines.
        var index = 0
        var sawMeta = false
        while index < lines.count {
            let trimmed = JS.trim(lines[index])
            if isCliMetaLine(trimmed) {
                sawMeta = true
                if wallTime == nil, let wt = JS.match(wallTimeLineRE, trimmed), let value = wt[1] {
                    wallTime = JS.trim(value)
                }
                index += 1
                continue
            }
            if sawMeta, trimmed.isEmpty {
                index += 1
                continue
            }
            break
        }

        if !sawMeta { return CliExecutionEnvelope(output: text, wallTime: nil) }

        while index < lines.count, JS.trim(lines[index]).isEmpty { index += 1 }
        return CliExecutionEnvelope(output: lines[index...].joined(separator: "\n"), wallTime: wallTime)
    }

    /// The text a command printed, with every wrapper agents put around it
    /// removed: a JSON envelope (`{stdout, stderr}`, codex's
    /// `{formatted_output, exit_code}`), codex's "Chunk ID / Wall time /
    /// Output:" framing, and a Markdown fence.
    static func normalizeCommandOutput(_ source: String) -> String {
        let normalized = commandOutputFromJsonString(source) ?? source
        return stripMarkdownCodeFence(parseCliExecutionEnvelope(normalized).output)
    }

    /// `^wall time…` under the `m` flag: JavaScript's `^` then also matches
    /// after `\n`, `\r`, U+2028 and U+2029 — spelled out so ICU's own list of
    /// line terminators does not apply.
    private static let wallTimeAnyLineRE = JS.regex(
        #"(?:^|(?<=[\n\r\x{2028}\x{2029}]))wall time\#(JS.s)*:\#(JS.s)*(\#(JS.dot)+)"#, ignoreCase: true)

    /// The raw "Wall time:" value codex reports, e.g. `0.0519 seconds`.
    private static func rawWallTime(_ source: String) -> String? {
        let normalized = commandOutputFromJsonString(source) ?? source
        guard let match = JS.match(wallTimeAnyLineRE, normalized), let value = match[1] else { return nil }
        return JS.trim(value)
    }

    private static let wallTimeSecondsRE = JS.regex(#"^([0-9.]+)\#(JS.s)*s"#)

    /// Codex's wall time in milliseconds, or nil when absent or unreadable.
    static func extractWallTimeMs(_ source: String?) -> Int? {
        guard let source, !source.isEmpty, let raw = rawWallTime(source),
              let numMatch = JS.match(wallTimeSecondsRE, raw), let digits = numMatch[1],
              let sec = JS.parseFloat(digits), sec.isFinite
        else { return nil }
        let ms = JS.mathRound(sec * 1000)
        guard ms.magnitude < Double(Int.max) else { return nil }
        return Int(ms)
    }

    // MARK: - Heredoc

    /// `<<PY`, `<<'PY'`, `<<"EOF"`, `<<-EOF` at the end of the first line.
    private static let heredocOpenerRE = JS.regex(
        #"<<-?\#(JS.s)*(['"]?)([A-Za-z_][A-Za-z0-9_\-]*)\1\#(JS.s)*\z"#)

    /// A command whose first line opens a heredoc — `python - <<'PY'` followed
    /// by the script — so the row can say "18-line script" instead of wrapping
    /// the whole program into the header.
    static func detectHeredoc(_ command: String) -> HeredocCommand? {
        let lines = JS.split(command, "\n")
        guard lines.count >= 2 else { return nil }
        let head = JS.trimEnd(lines[0])
        guard let opener = JS.match(heredocOpenerRE, head), let delimiter = opener[2] else { return nil }
        var close = -1
        for i in stride(from: lines.count - 1, through: 1, by: -1) where JS.trim(lines[i]) == delimiter {
            close = i
            break
        }
        let bodyLines = (close > 0 ? close : lines.count) - 1
        guard bodyLines > 0 else { return nil }
        return HeredocCommand(head: head, interpreter: interpreterOf(head), bodyLines: bodyLines)
    }

    private static let assignmentRE = JS.regex(#"^[A-Za-z_][A-Za-z0-9_]*="#)

    /// First program word of a command line, skipping `VAR=value` assignments.
    private static func interpreterOf(_ line: String) -> String? {
        for word in JS.splitWhitespace(JS.trim(line)) {
            if JS.test(assignmentRE, word) { continue }
            if word == "env" || word == "/usr/bin/env" { continue }
            if JS.startsWith(word, "<<") { return nil }
            let name = JS.afterLast(word, "/")
            return name.isEmpty ? nil : name
        }
        return nil
    }

    // MARK: - Exit status

    /// `[terminal exited: exit code: 1]`, `…: signal: SIGKILL]`, `…: finished]`.
    private static let terminalExitRE = JS.regex(#"\[terminal exited: ([^\]]*)\]\#(JS.s)*\z"#)
    private static let terminalCodeRE = JS.regex(#"exit code:\#(JS.s)*(-?[0-9]+)"#)
    private static let terminalSignalRE = JS.regex(#"signal:\#(JS.s)*([^,\]]+)"#)
    /// Claude Code / OpenCode 1.x: an `Exit code 1` line opening or closing the
    /// output.
    private static let exitCodeLineRE = JS.regex(
        #"^exit code[:\#(JS.wsClass)]\#(JS.s)*(-?[0-9]+)\#(JS.s)*\z"#, ignoreCase: true)
    /// Codex CLI framing: `Process exited with code 1` among the metadata lines.
    private static let processExitedRE = JS.regex(
        #"^process exited with code\#(JS.s)+(-?[0-9]+)\#(JS.s)*\z"#, ignoreCase: true)
    /// OpenCode 2's shell notice, a result block of its own after the output
    /// (packages/core/src/shell/result.ts `notice`). Through 2.2.6 it read
    /// `Exited with code 1`, or `Killed by SIGTERM`; from 2.2.7 it reads
    /// `Exit code: 1`, or `Exit code: 143 (SIGTERM)` (128 plus the signal's
    /// number), a timeout's explanation on the line before it. OpenCode
    /// completes such a command successfully. A numeric code also reaches the
    /// card as a field (see ``exitCodeMetaKey``); a signal, which OpenCode keeps
    /// in `metadata.signal`, is not lifted, so for a killed command the notice
    /// is what the card reads. 2.2.7's plain `Exit code: 1` is not read here:
    /// Claude Code's framing looks the same, and on a call that succeeded those
    /// words are the program's own.
    private static let openCodeExitedRE = JS.regex(
        #"^exited with code\#(JS.s)+(-?[0-9]+)\#(JS.s)*\z"#, ignoreCase: true)
    private static let openCodeKilledRE = JS.regex(
        #"^killed by\#(JS.s)+(SIG[A-Z0-9]+)\#(JS.s)*\z"#, ignoreCase: true)
    private static let openCodeSignalExitRE = JS.regex(
        #"^exit code:\#(JS.s)*-?[0-9]+\#(JS.s)+\((SIG[A-Z0-9]+)\)\#(JS.s)*\z"#, ignoreCase: true)

    /// `_meta` key carrying a command's exit code where the agent reports it as
    /// a field (OpenCode 2's `rawOutput.metadata.exit`, lifted by the backend).
    /// Backend twin: `EXIT_CODE_META_KEY` in `src-tauri/src/acp/connection.rs`.
    static let exitCodeMetaKey = "codeg.exitCode"

    /// The exit code a call's `_meta` reports (see ``exitCodeMetaKey``).
    static func exitFromMeta(_ meta: Any?) -> CommandExit? {
        guard let obj = meta as? [String: Any], let code = ActivityJSON.int(obj[exitCodeMetaKey]) else { return nil }
        return CommandExit(code: code, signal: nil)
    }

    /// The exit the AGENT reported in its framing of a command's result, as
    /// opposed to anything the program printed: OpenCode 2's closing notice.
    /// Only the result's last line is read — anywhere else the same words are
    /// the program's own output.
    static func extractAgentReportedExit(_ source: String?) -> CommandExit? {
        guard let source, !source.isEmpty else { return nil }
        guard let last = JS.split(source, "\n").map(JS.trim).last(where: { !$0.isEmpty }) else { return nil }
        if let exited = JS.match(openCodeExitedRE, last) {
            return exitCode(exited[1])
        }
        if let killed = JS.match(openCodeKilledRE, last) ?? JS.match(openCodeSignalExitRE, last),
           let signal = killed[1] {
            return CommandExit(code: nil, signal: signal)
        }
        return nil
    }

    /// `{code: Number(digits), signal: null}`. A code too large for `Int` (the
    /// web would carry it as a float) reads as no code at all.
    private static func exitCode(_ digits: String?) -> CommandExit? {
        guard let digits, let code = Int(digits) else { return nil }
        return CommandExit(code: code, signal: nil)
    }

    private static func exitFromTerminalLine(_ text: String) -> CommandExit? {
        guard let match = JS.match(terminalExitRE, JS.trimEnd(text)), let body = match[1] else { return nil }
        let code = JS.match(terminalCodeRE, body)?[1]
        let signal = JS.match(terminalSignalRE, body)?[1]
        if code == nil, signal == nil { return nil }
        if let code, Int(code) == nil { return nil }
        return CommandExit(code: code.flatMap { Int($0) }, signal: signal.map(JS.trim))
    }

    private static func exitFromFramingLines(_ text: String) -> CommandExit? {
        let nonEmpty = JS.split(text, "\n").map(JS.trim).filter { !$0.isEmpty }
        guard let lastLine = nonEmpty.last else { return nil }
        // The opening metadata block (codex framing) and the first / last line
        // (Claude Code, OpenCode) are the only places these appear; a match in
        // the middle of the output is the program's own text.
        for line in nonEmpty.prefix(8) {
            if let exited = JS.match(processExitedRE, line) ?? JS.match(exitCodeLineRE, line) {
                return exitCode(exited[1])
            }
            if !isCliMetaLine(line) { break }
        }
        if let last = JS.match(exitCodeLineRE, lastLine) { return exitCode(last[1]) }
        return extractAgentReportedExit(text)
    }

    /// The exit status a command's result reports, read in order of
    /// reliability: codex's `{exit_code}` envelope, the `[terminal exited: …]`
    /// line the backend appends for terminals it hosts, then the `Exit code N`
    /// / `Process exited with code N` text agents put around the output. Nil
    /// when none is present — a failed call without one is reported as plainly
    /// "failed", never with an invented code.
    static func extractCommandExit(_ source: String?) -> CommandExit? {
        guard let source, !source.isEmpty else { return nil }
        if let envelope = CodexCommandEnvelope.parse(source) {
            return CommandExit(code: envelope.exitCode, signal: nil)
        }
        let parsed = JS.startsWith(JS.trimStart(source), "{") ? ActivityJSON.tryParse(source) : nil
        if let parsed {
            // `parsed.exit_code ?? parsed.exitCode`: `??` only skips a missing
            // key or a JSON null.
            let reported = ["exit_code", "exitCode"].lazy.compactMap { parsed[$0] }.first { !($0 is NSNull) }
            if let code = ActivityJSON.int(reported) { return CommandExit(code: code, signal: nil) }
        }
        let text = commandOutputFromJsonString(source) ?? source
        // claude-agent-acp fences a failed result for clients without a
        // terminal channel, which pushes its `Exit code N` line down to the
        // second.
        let body = JS.startsWith(JS.trimStart(text), "```") ? stripMarkdownCodeFence(text) : text
        return exitFromTerminalLine(body) ?? exitFromFramingLines(body)
    }
}

// MARK: - JavaScript string & regex semantics

extension ActivityCommand {
    /// The JavaScript string and regex semantics the activity ports lean on,
    /// made explicit so ICU and Swift's grapheme-based `String` do not quietly
    /// change a rule:
    ///
    /// - `trim`/`\s` use ECMAScript's whitespace set (WhiteSpace +
    ///   LineTerminator), which differs from `CharacterSet.whitespacesAndNewlines`.
    /// - `\d`/`\w`/`\b` are ASCII in JavaScript; ICU's are Unicode — patterns
    ///   spell `[0-9]`, `[A-Za-z0-9_]` and look-arounds instead.
    /// - JavaScript's `$` (no `m` flag) is the end of input only; ICU's also
    ///   matches before a final line break — patterns use `\z`.
    /// - JavaScript's `.` stops at `\n`, `\r`, U+2028, U+2029 only — ``dot``.
    /// - Splitting and prefix tests work on Unicode scalars: a `\r\n` is one
    ///   `Character` in Swift, so `split(separator: "\n")` would not see it.
    enum JS {
        /// ECMAScript `\s`, for use inside a character class.
        static let wsClass = #"\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}"#
        /// ECMAScript `\s`.
        static let s = "[\(wsClass)]"
        /// ECMAScript `\S`.
        static let S = "[^\(wsClass)]"
        /// ECMAScript `.` (no `s` flag).
        static let dot = #"[^\n\r\x{2028}\x{2029}]"#

        static func regex(_ pattern: String, ignoreCase: Bool = false) -> NSRegularExpression {
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
        }

        /// `re.test(s)`.
        static func test(_ re: NSRegularExpression, _ s: String) -> Bool {
            re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }

        /// `s.match(re)` for a non-global regex: the whole match at index 0,
        /// then each group (nil when it did not take part).
        static func match(_ re: NSRegularExpression, _ s: String) -> [String?]? {
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }

        /// `s.replace(re, "")` for a non-global regex.
        static func replaceFirst(_ re: NSRegularExpression, in s: String) -> String {
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return s }
            return ns.replacingCharacters(in: m.range, with: "")
        }

        static func isWhitespace(_ u: Unicode.Scalar) -> Bool {
            switch u.value {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A,
                 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
                return true
            default:
                return false
            }
        }

        static func trim(_ s: String) -> String { trimEnd(trimStart(s)) }

        static func trimStart(_ s: String) -> String {
            let scalars = s.unicodeScalars
            guard let first = scalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
            return first == scalars.startIndex ? s : String(scalars[first...])
        }

        static func trimEnd(_ s: String) -> String {
            let scalars = s.unicodeScalars
            guard let last = scalars.lastIndex(where: { !isWhitespace($0) }) else { return "" }
            let end = scalars.index(after: last)
            return end == scalars.endIndex ? s : String(scalars[..<end])
        }

        /// `s.split(separator)` for a one-scalar separator; keeps empty pieces.
        static func split(_ s: String, _ separator: Unicode.Scalar) -> [String] {
            s.unicodeScalars.split(separator: separator, omittingEmptySubsequences: false).map { String($0) }
        }

        /// `s.split(/\s+/)` of an already trimmed string (`""` → `[""]`).
        static func splitWhitespace(_ s: String) -> [String] {
            let pieces = s.unicodeScalars.split(whereSeparator: isWhitespace).map { String($0) }
            return pieces.isEmpty ? [""] : pieces
        }

        static func startsWith(_ s: String, _ prefix: String) -> Bool {
            s.unicodeScalars.starts(with: prefix.unicodeScalars)
        }

        static func endsWith(_ s: String, _ suffix: String) -> Bool {
            s.unicodeScalars.reversed().starts(with: suffix.unicodeScalars.reversed())
        }

        /// `s.slice(s.lastIndexOf(char) + 1)`.
        static func afterLast(_ s: String, _ char: Unicode.Scalar) -> String {
            let scalars = s.unicodeScalars
            guard let i = scalars.lastIndex(of: char) else { return s }
            return String(scalars[scalars.index(after: i)...])
        }

        /// The string less `dropFirst` leading and `dropLast` trailing scalars.
        static func sliceScalars(_ s: String, dropFirst: Int, dropLast: Int) -> String {
            String(String.UnicodeScalarView(s.unicodeScalars.dropFirst(dropFirst).dropLast(dropLast)))
        }

        /// `parseFloat` of a `[0-9.]+` string: the longest `digits[.digits]`
        /// prefix; nil (NaN) when it has no digit.
        static func parseFloat(_ s: String) -> Double? {
            var intPart = "", fracPart = ""
            var scalars = s.unicodeScalars[...]
            while let c = scalars.first, ("0"..."9").contains(c) { intPart.unicodeScalars.append(c); scalars.removeFirst() }
            if scalars.first == "." {
                scalars.removeFirst()
                while let c = scalars.first, ("0"..."9").contains(c) { fracPart.unicodeScalars.append(c); scalars.removeFirst() }
            }
            if intPart.isEmpty, fracPart.isEmpty { return nil }
            return Double("\(intPart.isEmpty ? "0" : intPart).\(fracPart.isEmpty ? "0" : fracPart)")
        }

        /// `Math.round`: halves round toward +∞.
        static func mathRound(_ x: Double) -> Double {
            let floor = x.rounded(.down)
            return x - floor >= 0.5 ? floor + 1 : floor
        }
    }
}
