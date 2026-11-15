import Foundation

/// Parsers for the two codex tool shapes that carry no command of their own and
/// therefore rendered as bare, contentless cards: the unified-exec session tools
/// (`wait` / `write_stdin`) and the code-mode script (`codex_script`).
///
/// Ports web `lib/shell-session-tool.ts` and `lib/codex-code-mode.ts`.

// MARK: - Unified-exec session tools

/// A `wait` / `write_stdin` call. Neither carries a command: both address a
/// background shell an earlier `exec_command` started, by the id that command's
/// output announced (`wait` calls it `cell_id`, `write_stdin` calls it
/// `session_id`). Rendered from the raw arguments they were a bare "Bash" card
/// over a `{"cell_id":"7106","yield_time_ms":30000}` parameter dump.
///
/// The history parser (`src-tauri/src/parsers/codex.rs`) resolves the id back to
/// that command and adds it as `session_command`, so the card can be titled by
/// the command it is waiting on. The field is absent when the id was never
/// announced in the transcript — the card then names the session id instead.
struct ShellSessionCall {
    /// `cell_id` / `session_id`, normalized to a string (codex sends both).
    let sessionId: String?
    /// Command that started the session, resolved by the history parser.
    let command: String?
    /// Keystrokes sent (`write_stdin` only). Empty means "just poll".
    let chars: String
    /// `wait` may ask to kill the session instead of waiting on it.
    let terminate: Bool

    /// Canonical (post-`canonical(_:)`) names of the two session tools.
    static let waitName = "wait"
    static let writeStdinName = "write_stdin"

    static func isSessionToolName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n == waitName || n == writeStdinName
    }

    static func parse(input: String?) -> ShellSessionCall? {
        guard let record = ToolDerive.parseJSON(input) else { return nil }
        let command = (record["session_command"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ShellSessionCall(
            sessionId: readId(record["cell_id"]) ?? readId(record["session_id"]),
            command: (command?.isEmpty ?? true) ? nil : command,
            chars: record["chars"] as? String ?? "",
            terminate: readBool(record["terminate"])
        )
    }

    /// A strict JSON boolean. `as? Bool` alone would also accept the numbers 0
    /// and 1 (Swift bridges an `NSNumber` either way), where the web tests
    /// `=== true` and Rust `as_bool()` — so `terminate: 1` would read as a kill.
    private static func readBool(_ value: Any?) -> Bool {
        guard let value, ToolJSONFormat.isBoolean(value) else { return false }
        return (value as? NSNumber)?.boolValue == true
    }

    /// codex sends the id as either a string or a number.
    private static func readId(_ value: Any?) -> String? {
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        // `as? NSNumber` rather than `Int`: JSONSerialization hands back an
        // NSNumber. The boolean exclusion goes through `isBoolean` because
        // `value is Bool` is TRUE for the numbers 0 and 1 as well — which would
        // drop two ids the web and Rust parsers both accept.
        guard let value, !ToolJSONFormat.isBoolean(value), let n = value as? NSNumber else { return nil }
        return n.stringValue
    }
}

enum ShellSessionFormat {
    private static let namedControlChars: [Character: String] = [
        "\n": "⏎", "\r": "⏎", "\t": "⇥", "\u{7f}": "^?",
    ]

    /// Render keystrokes sent to a session as something readable in a title —
    /// the payload is usually a control character (`Ctrl-C` to interrupt, a bare
    /// newline to confirm a prompt), which would otherwise be invisible.
    ///
    /// The walk STOPS at `maxLen` rendered characters rather than expanding the
    /// whole payload and then trimming: `chars` is whatever the agent typed into
    /// the shell, a paste can be megabytes, and this runs during `ToolCallVM`
    /// construction on the main actor — for a card header that shows 40 of them.
    static func describeStdin(_ chars: String, maxLen: Int = 40) -> String {
        var out = ""
        var truncated = false
        for ch in chars {
            if out.count >= maxLen { truncated = true; break }
            if let named = namedControlChars[ch] { out += named; continue }
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
                out.append(ch)
                continue
            }
            // Remaining C0 controls render as caret notation (`Ctrl-C` → `^C`).
            if scalar.value < 0x20, let caret = Unicode.Scalar(scalar.value + 64) {
                out += "^\(Character(caret))"
            } else {
                out.append(ch)
            }
        }
        // Trim AFTER the cap so leading/trailing whitespace in the payload
        // doesn't leave a ragged title; a caret pair may push one over the cap.
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard truncated || out.count > maxLen else { return out }
        return String(out.prefix(max(0, maxLen - 1))) + "…"
    }

    /// The line a code-mode script prints to publish the session it just started:
    ///
    /// ```js
    /// const r = await tools.exec_command({ cmd: "npx playwright install", … })
    /// if (r.session_id) text(`SESSION_ID=${r.session_id}`)
    /// ```
    ///
    /// codex's own announcements never reach the card — the prose envelope is
    /// dropped with everything above the `Output:` line, and the code-mode JSON
    /// one is unwrapped to its `output` field. The script's echo above is the
    /// only one that survives, and it is exactly the case the history parser
    /// cannot resolve, so the `wait` calls polling such a session stay titled by
    /// the bare id. Showing the same id on the command card is what lets the two
    /// be matched up.
    ///
    /// Anchored to the whole line, uppercase, digits only — the single spelling
    /// real transcripts use, and tight enough that a command merely mentioning
    /// the words cannot mint an id.
    private static let announcedSessionID = try? NSRegularExpression(
        pattern: #"^[ \t]*SESSION_ID[ \t]*=[ \t]*(\d+)[ \t\r]*$"#,
        options: [.anchorsMatchLines]
    )

    static func announcedSessionId(in output: String?) -> String? {
        guard let output, !output.isEmpty, let regex = announcedSessionID else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let idRange = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[idRange])
    }
}

// MARK: - Command actions

/// codex-acp "command action" tool calls.
///
/// When codex classifies a shell command as a known action (read / search /
/// list-files), codex-acp announces it as an ACP `tool_call` carrying ONLY a
/// human title — no input at all — and later completes it with a
/// `{formatted_output, exit_code}` envelope. The query and the path therefore
/// exist nowhere but the title, so the classifier has to read them back out of
/// it; without this the whole title becomes the "tool name", giving no search
/// icon, an "other" tool-group tally, and a body that dumps the raw envelope.
///
/// The title shapes are codex-acp's own literals. Note the asymmetric quoting —
/// the search path is NOT quoted, every other interpolation is:
///
///     Search for '<query>' in <path>
///     Search for '<query>'
///     Search in '<path>'
///     Search
///     List files in '<path>'
///     List files
///     Read file '<path>'            ← the file only: the card needs it as its input
///
/// Ports web `lib/codex-command-action.ts`; the read is Android's
/// (`CodexCommandAction.kt`), since the web takes a read's file from the ACP
/// `locations`, which this client doesn't keep.
enum CodexCommandAction {
    struct Search {
        /// Search pattern, or nil when codex could not extract one.
        let query: String?
        /// Directory / file the search was scoped to, nil for a whole-tree search.
        let path: String?
    }

    private static let searchForPrefix = "Search for '"
    /// Separator between a quoted query and the UNQUOTED path. Matched from the
    /// RIGHT: a path never contains `' in `, but a query may.
    private static let queryPathSeparator = "' in "

    /// A bare "Search" is a SUCCESSFUL parse with both fields nil — the caller
    /// distinguishes it from "not a search title" by the optional itself.
    static func search(title: String?) -> Search? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if trimmed == "Search" { return Search(query: nil, path: nil) }

        if trimmed.hasPrefix(searchForPrefix) {
            let rest = trimmed.dropFirst(searchForPrefix.count)
            if let sep = rest.range(of: queryPathSeparator, options: .backwards),
               sep.lowerBound > rest.startIndex {
                let query = String(rest[rest.startIndex..<sep.lowerBound])
                let path = rest[sep.upperBound...].trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { return Search(query: query, path: path) }
            }
            if rest.hasSuffix("'") {
                let query = String(rest.dropLast())
                if !query.isEmpty { return Search(query: query, path: nil) }
            }
            return nil
        }

        if let path = quoted(trimmed, after: "Search in ") {
            return Search(query: nil, path: path)
        }
        return nil
    }

    private static let readFilePrefix = "Read file '"

    /// The file a `Read file '<path>'` title names, or nil. One quoted path
    /// only — a path holding no `'` — because codex-acp joins the titles of a
    /// multi-command line with ", ", and `Read file 'a', Read file 'b'` must not
    /// read as one file called `a', Read file 'b`.
    static func readFile(title: String?) -> String? {
        guard let scalars = title?.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars,
              scalars.starts(with: readFilePrefix.unicodeScalars), scalars.last == "'" else { return nil }
        let inner = scalars.dropFirst(readFilePrefix.unicodeScalars.count).dropLast()
        guard !inner.isEmpty, !inner.contains("'") else { return nil }
        return String(String.UnicodeScalarView(inner))
    }

    /// A codex-acp list-files title's path, or nil when the title isn't one.
    /// A bare "List files" parses to a non-nil action with a nil path.
    static func listFiles(title: String?) -> String?? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if trimmed == "List files" { return .some(nil) }
        if let path = quoted(trimmed, after: "List files in ") { return .some(path) }
        return nil
    }

    /// A command action resolved from its title: the canonical tool name the
    /// web maps it to, plus the arguments read back out of the title — which is
    /// the only place they exist. A saved codex command resolves to the same
    /// (`CodexShellAction`).
    struct Resolved {
        /// `read`, `grep` or `glob`, matching web `normalizeToolName`.
        let name: String
        /// Synthesized `input_preview` JSON, matching what the desktop's
        /// runtime writes onto the tool-use block.
        let input: String
        /// Exit code 1 means "nothing selected" for grep-likes only; for the
        /// list commands that classify as `glob` it is a real failure.
        var isGrepLike: Bool { name == "grep" }
    }

    /// Resolve a title-only command action. Callers must only try this when the
    /// call carries NO input of its own — that is the shape codex-acp sends, and
    /// a tool with real arguments should never be re-identified by its title.
    static func resolve(title: String) -> Resolved? {
        // A read names its file in the title only: as `file_path` it gives the
        // card "Read <file>" and the file view, as a read's saved copy has.
        if let path = readFile(title: title) {
            return Resolved(name: "read", input: encode(["file_path": path]))
        }
        if let action = search(title: title) {
            var args: [String: String] = [:]
            if let query = action.query { args["pattern"] = query }
            if let path = action.path { args["path"] = path }
            return Resolved(name: "grep", input: encode(args))
        }
        if let path = listFiles(title: title) {
            var args: [String: String] = [:]
            if let path { args["path"] = path }
            return Resolved(name: "glob", input: encode(args))
        }
        return nil
    }

    /// The synthesized input as JSON text, keys sorted. Slashes unescaped, as
    /// `JSON.stringify` writes them: these are mostly paths.
    static func encode(_ args: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: args,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// `<prefix>'<value>'` with a non-empty value. Written as a prefix/suffix
    /// test rather than a regex so a value containing `'` (or a newline, which
    /// `$` would break on) still parses.
    private static func quoted(_ text: String, after prefix: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        guard rest.hasPrefix("'"), rest.hasSuffix("'"), rest.count >= 3 else { return nil }
        return String(rest.dropFirst().dropLast())
    }
}

/// codex-acp's command-execution result envelope, which always sends BOTH
/// `formatted_output` and `exit_code`. Requiring both keys keeps a genuine JSON
/// payload (`{output: …}`, `{stdout: …}`, a lone `{exit_code: 0}`, …) from being
/// mistaken for the envelope — the looser `ToolOutputFormat.commandOutput`
/// would silently turn such a result into empty text, i.e. "No matches".
/// Ports web `parseCodexCommandEnvelope`.
struct CodexCommandEnvelope {
    let output: String
    let exitCode: Int

    static func parse(_ raw: String?) -> CodexCommandEnvelope? {
        guard let raw, let obj = ToolDerive.parseJSON(raw),
              let code = obj["exit_code"] as? NSNumber, !ToolJSONFormat.isBoolean(code),
              let output = obj["formatted_output"] as? String
        else { return nil }
        return CodexCommandEnvelope(output: output, exitCode: code.intValue)
    }
}

// MARK: - Code-mode script

/// Newer codex wraps every tool call in a JS script and persists the whole
/// script as ONE rollout record. The history parser
/// (`src-tauri/src/parsers/codex_code_mode.rs`) recovers the inner
/// `tools.<name>(…)` calls and re-emits them as the tool calls codex wrote
/// before code mode, so the existing cards keep working.
///
/// When a script cannot be decomposed (variable destructuring, a command built
/// in a loop, template interpolation) the parser emits this synthetic tool
/// instead of guessing — its input carries the raw script for a JS code block.
struct CodexScriptCard {
    /// Raw JS source codex executed.
    let source: String
    /// Best-effort title (the first command the parser could read).
    let title: String?
    /// Number of `tools.*` call sites detected in the script.
    let callCount: Int

    /// The exact wire name. MUST stay an exact match: a freeform `exec` rule
    /// would otherwise collapse it to a shell tool and render the JS source as a
    /// command.
    static let toolName = "codex_script"

    static func parse(input: String?) -> CodexScriptCard? {
        guard let record = ToolDerive.parseJSON(input),
              let source = record["source"] as? String else { return nil }
        let count = record["call_count"] as? NSNumber
        return CodexScriptCard(
            source: source,
            title: record["title"] as? String,
            callCount: count?.intValue ?? 0
        )
    }
}
