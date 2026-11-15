import Foundation

/// "No matches" for a codex search that arrives as a bare FAILED call — the
/// live shape of the web's `isGrepNoMatchResult` (`ai-elements-adapter.ts`,
/// codeg 0.44), with the guards of Android's `GrepNoMatch.kt`.
///
/// rg / grep exit 1 when they select nothing, and codex derives a call's status
/// from the exit code alone, so a healthy negative search is reported as
/// failed. codeg advertises `_meta.terminal_output_delta` to codex, and with it
/// codex-acp stops sending `rawOutput` on completion: a search that printed
/// nothing then arrives as a bare `failed`, with no envelope and so no exit code
/// to read. Output is the discriminator left — rg prints a diagnostic on a real
/// failure (exit 2), and that streams in like any other output. The server
/// marks codex's own search actions (`codexSearchActionMetaKey`), which is what
/// keeps this to codex: another adapter's interrupted grep can look exactly the
/// same. A persisted row carries neither the mark nor a status.
///
/// The two other no-match shapes are read elsewhere: codex's exit-1 empty
/// envelope by the search row and card (`ActivityExplore.searchResultText`,
/// `ToolCallVM.searchResultText`), a shell search's exit 1 by the command row
/// (`ActivityExitMeaning`) — or, for a saved codex command that reads back as
/// the search it streamed as, by `CodexShellAction.isNoMatchResult`.
enum GrepNoMatch {
    /// `_meta` key the server stamps on codex's `search` command actions
    /// (`stamp_codex_search_action` in `acp/connection.rs`; web
    /// `CODEX_SEARCH_ACTION_META_KEY`).
    static let codexSearchActionMetaKey = "codeg.codexSearchAction"

    /// Whether a FAILED call is codex's own search that found nothing: marked
    /// by the server, resolving to `grep` (so never a `wait` / `write_stdin`
    /// session poll or a script cell), with nothing printed. The caller checks
    /// the failure itself (a live `failed` status).
    ///
    /// codex's search action carries no command — only its title — so the
    /// input normally names none. Should one arrive with a command after all,
    /// it must be one plain pipeline ending in the search (``endsInGrepSearch(_:)``):
    /// a leading `!`, a last-stage redirection that can fail, `$(…)` or a
    /// heredoc keep the failure a failure.
    static func isCodexSearchNoMatch(toolName: String, input: String?, output: String?, meta: AnyJSON?) -> Bool {
        guard meta?[codexSearchActionMetaKey]?.bool == true else { return false }
        guard (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard ToolNameNormalizer.normalizeToolName(toolName) == "grep" else { return false }
        if let command = commandFromToolInput(input) { return endsInGrepSearch(command) }
        return true
    }

    // MARK: - The command a call ran (web `grep-no-match.ts`)

    /// What a shell call ran: a script for the shell to split, or an argv.
    enum Command: Equatable {
        case script(String)
        case argv([String])
    }

    private static let grepCommands: Set<String> = ["rg", "grep", "egrep", "fgrep"]
    private static let shells: Set<String> = ["sh", "bash", "zsh"]
    /// How many `sh -c '…'` wrappers to look through (`/bin/zsh -lc "bash -c …"`).
    private static let maxWrappers = 3

    /// The command a call's input names: `{command}` / `{cmd}` (a script or an
    /// argv), a bare JSON string or argv, or the raw text itself when the input
    /// is not JSON at all. Nil for input naming no command (`{pattern, path}`).
    static func commandFromToolInput(_ input: String?) -> Command? {
        guard let trimmed = input?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard let parsed = AnyJSON.parse(jsonString: trimmed) else { return .script(trimmed) }
        func read(_ value: AnyJSON?) -> Command? {
            switch value {
            case .string(let script)?:
                return .script(script)
            case .array(let items)?:
                let words = items.compactMap(\.string)
                return !items.isEmpty && words.count == items.count ? .argv(words) : nil
            default:
                return nil
            }
        }
        if let object = parsed.object {
            for key in ["command", "cmd"] {
                if let command = read(object[key]) { return command }
            }
            return nil
        }
        return read(parsed)
    }

    /// Whether `command` exits with the status of a grep-like search: ONE
    /// pipeline whose last stage runs rg / grep / egrep / fgrep, read through
    /// any `sh|bash|zsh -c` / `-lc` wrapper. A pipeline exits with its last
    /// stage's status; a leading `!` inverts it and is refused.
    static func endsInGrepSearch(_ command: Command) -> Bool {
        var stages: [[String]]?
        switch command {
        case .script(let script): stages = pipelineStages(script)
        case .argv(let words): stages = [words]
        }
        var unwrapped = 0
        while let current = stages, unwrapped <= maxWrappers {
            guard current.count == 1, let script = shellWrapperScript(current[0]) else {
                guard let first = current.first, let last = current.last else { return false }
                return first.first != "!" && isGrepInvocation(last)
            }
            stages = pipelineStages(script)
            unwrapped += 1
        }
        return false
    }

    /// `<script>` of `bash -lc '<script>'`, `/bin/zsh -lc "<script>"`, `sh -c …`.
    private static func shellWrapperScript(_ words: [String]) -> String? {
        guard words.count == 3, let shell = programName(words[0]), shells.contains(shell),
              words[1] == "-c" || words[1] == "-lc" else { return nil }
        return words[2]
    }

    private static func isGrepInvocation(_ words: [String]) -> Bool {
        var index = 0
        while index < words.count, isAssignment(words[index]) { index += 1 }
        guard index < words.count, let name = programName(words[index]) else { return false }
        return grepCommands.contains(name)
    }

    /// `NAME=value` in front of a command (`LC_ALL=C grep …`).
    private static func isAssignment(_ word: String) -> Bool {
        var sawName = false
        for scalar in word.unicodeScalars {
            if scalar == "=" { return sawName }
            let letter = (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
                || scalar == "_"
            let digit = scalar.value >= 48 && scalar.value <= 57
            if !(letter || (sawName && digit)) { return false }
            sawName = true
        }
        return false
    }

    /// The program a command word runs (`/opt/homebrew/bin/rg` → `rg`), or nil
    /// when the word is not one the shell runs exactly as written —
    /// `${IFS:+false$IFS}/grep` runs `false`.
    private static func programName(_ word: String) -> String? {
        guard !word.isEmpty, word.unicodeScalars.allSatisfy(isPlainWordScalar) else { return nil }
        guard let slash = word.lastIndex(of: "/") else { return word }
        return String(word[word.index(after: slash)...])
    }

    /// `[\w./+-]`, ASCII as in JavaScript.
    private static func isPlainWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122: return true
        default: return scalar == "_" || scalar == "." || scalar == "/" || scalar == "+" || scalar == "-"
        }
    }

    /// What a redirection does with its target: open it for output, copy a
    /// descriptor onto it (`>&`), or open it for input (`<`, `<>`, `<&`).
    private enum Redirect { case output, duplicate, input }

    /// Whether the shell can fail to set up a redirection — it then exits 1
    /// without running the command, as silently as a search that found nothing
    /// once a `2>/dev/null` came first. Writing to /dev/null and copying stdout
    /// / stderr cannot fail; opening anything else can.
    private static func redirectionCanFail(_ kind: Redirect, _ target: String) -> Bool {
        switch kind {
        case .output: return target != "/dev/null"
        case .duplicate: return target != "1" && target != "2" && target != "/dev/null"
        case .input: return true
        }
    }

    /// The words of each stage of `script` when it is ONE pipeline of simple
    /// commands, or nil for anything else (web `pipelineStages`).
    ///
    /// A recognizer for that one shape, not a shell parser. Whatever could make
    /// the exit status come from somewhere other than the last stage's command
    /// — `&&`, `||`, `;`, `&`, a newline, a subshell, `|&`, or a redirection on
    /// that stage the shell could fail to set up — and whatever this reader
    /// cannot follow — command and process substitution, `$'…'`, a heredoc, a
    /// comment, an unterminated quote — answers nil. Quotes and backslashes
    /// resolve the POSIX way, so a `|` inside a quoted pattern stays part of it.
    /// Walks Unicode scalars (the web walks UTF-16 units): every character it
    /// acts on is ASCII.
    static func pipelineStages(_ script: String) -> [[String]]? {
        let chars = Array(script.unicodeScalars)
        var stages: [[String]] = [[]]
        var word = String.UnicodeScalarView()
        var inWord = false
        // Set while the next word is a redirection's target, not an argument.
        var pendingRedirect: Redirect?
        // The current stage has a redirection the shell could fail to set up.
        var stageRedirectCanFail = false

        func endWord() {
            guard inWord else { return }
            let text = String(word)
            if let pending = pendingRedirect {
                if redirectionCanFail(pending, text) { stageRedirectCanFail = true }
                pendingRedirect = nil
            } else {
                stages[stages.count - 1].append(text)
            }
            word = String.UnicodeScalarView()
            inWord = false
        }
        func at(_ index: Int) -> Unicode.Scalar? { index < chars.count ? chars[index] : nil }
        func isDigits(_ text: String.UnicodeScalarView) -> Bool {
            !text.isEmpty && text.allSatisfy { $0.value >= 48 && $0.value <= 57 }
        }

        var index = 0
        while index < chars.count {
            let char = chars[index]
            let next = at(index + 1)
            switch char {
            case " ", "\t":
                endWord()
            case "'":
                guard let close = chars[(index + 1)...].firstIndex(of: "'") else { return nil }
                word.append(contentsOf: chars[(index + 1)..<close])
                inWord = true
                index = close
            case "\"":
                var cursor = index + 1
                while cursor < chars.count, chars[cursor] != "\"" {
                    let quoted = chars[cursor]
                    let after = at(cursor + 1)
                    if quoted == "`" || (quoted == "$" && after == "(") { return nil }
                    if quoted == "\\", let after, "$`\"\\\n".unicodeScalars.contains(after) {
                        if after != "\n" { word.append(after) }
                        cursor += 2
                        continue
                    }
                    word.append(quoted)
                    cursor += 1
                }
                if cursor >= chars.count { return nil }
                inWord = true
                index = cursor
            case "\\":
                guard let escaped = next else { return nil }
                index += 1
                if escaped != "\n" {
                    word.append(escaped)
                    inWord = true
                }
            case "|":
                if next == "|" || next == "&" { return nil }
                endWord()
                if pendingRedirect != nil || stages[stages.count - 1].isEmpty { return nil }
                stages.append([])
                stageRedirectCanFail = false
            case "<", ">":
                if next == "(" || (char == "<" && next == "<") { return nil }
                // A bare number right before the operator is its descriptor (`2>`).
                if inWord, pendingRedirect == nil, isDigits(word) {
                    word = String.UnicodeScalarView()
                    inWord = false
                } else {
                    endWord()
                }
                // Still waiting for a target: two operators in a row.
                if pendingRedirect != nil { return nil }
                if char == "<" {
                    pendingRedirect = Redirect.input
                } else {
                    pendingRedirect = next == "&" ? Redirect.duplicate : Redirect.output
                }
                // The rest of a two-character operator: `>>`, `>&`, `>|`, `<>`, `<&`.
                if next == ">" || next == "&" || (char == ">" && next == "|") { index += 1 }
            case "&":
                // `&>file` / `&>>file`; any other `&` is `&&` or a background job.
                if next != ">" { return nil }
                endWord()
                if pendingRedirect != nil { return nil }
                index += at(index + 2) == ">" ? 2 : 1
                pendingRedirect = Redirect.output
            case "$":
                // `$(…)` runs a command; `$'…'` quotes by rules of its own.
                if next == "(" || next == "'" { return nil }
                word.append(char)
                inWord = true
            case "#":
                if !inWord { return nil }
                word.append(char)
            case ";", "\n", "\r", "(", ")", "`":
                return nil
            default:
                word.append(char)
                inWord = true
            }
            index += 1
        }
        endWord()
        if pendingRedirect != nil || stageRedirectCanFail { return nil }
        if stages.contains(where: \.isEmpty) { return nil }
        return stages
    }
}
