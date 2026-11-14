import Foundation

/// What a command's non-zero exit says, read off the command that set it —
/// port of the web's `src/lib/activity/exit-meaning.ts` (codeg 0.44).
///
/// A handful of commands answer a question with exit 1: a search that matched
/// nothing, a test that came out false, two files that differ, a name or a
/// path that is not there. That is the answer, not a failure — Claude Code's
/// Bash tool reads exit 1 from grep / rg / diff / test the same way, and Codex
/// greys a search's exit 1 rather than calling it failed — so such a command
/// settles as done, its figure saying what it found.
///
/// Read conservatively, since a wrong guess hides a real failure: the status
/// must come from that command — the last of a pipeline or a list, or the one
/// before an `&& echo …` it stopped — anything chained ahead of it with `&&`
/// must be setup that complains when it fails (`cd`), what it printed must fit
/// the answer (a search that found nothing prints nothing), and a line that
/// does anything this reader does not follow — a substitution, a subshell, a
/// heredoc, `set -e` — keeps its exit a failure.
///
/// A failure stays one, in words where the shell has them, as shell prompts
/// (Starship, Powerlevel10k, fish) spell the codes out: 127 is a command not
/// found, 126 one that cannot run, 128 + n a kill by signal n.
enum ActivityExitMeaning {
    private typealias JS = ActivityCommand.JS

    /// Whether the meaning is an answer — the command succeeded.
    static func isExitAnswer(_ meaning: ExitMeaning?) -> Bool {
        meaning?.isAnswer ?? false
    }

    /// 128 + n for the signals numbered alike on Linux and macOS.
    private static let signalByCode: [Int: String] = [
        129: "SIGHUP",
        130: "SIGINT",
        131: "SIGQUIT",
        134: "SIGABRT",
        137: "SIGKILL",
        139: "SIGSEGV",
        141: "SIGPIPE",
        142: "SIGALRM",
        143: "SIGTERM",
    ]

    /// The signal a 128 + n exit code stands for, when it is one of those.
    static func signalOfExitCode(_ code: Int?) -> String? {
        code.flatMap { signalByCode[$0] }
    }

    // MARK: - Reading the command line

    private enum Joiner { case and, or, pipe, semicolon }

    private struct SimpleCommand {
        var words: [String]
        /// How it is joined to the command before it; nil for the first.
        var after: Joiner?
    }

    /// The line split into simple commands at its top-level operators, quotes
    /// resolved, or nil when it does something this reader does not follow.
    ///
    /// Walks Unicode scalars (the web walks UTF-16 code units): every
    /// character the reader acts on is ASCII, and the rest is copied into
    /// words verbatim either way.
    private static func splitCommandLine(_ line: String) -> [SimpleCommand]? {
        let chars = Array(line.unicodeScalars)
        var commands: [SimpleCommand] = []
        var words: [String] = []
        var word = String.UnicodeScalarView()
        var inWord = false
        var after: Joiner?

        func endWord() {
            if inWord { words.append(String(word)) }
            word = String.UnicodeScalarView()
            inWord = false
        }
        // An operator with no command before it (`; ;`, a leading `|`) is not
        // a line this reader follows.
        func endCommand(_ joiner: Joiner) -> Bool {
            endWord()
            if words.isEmpty { return joiner == .semicolon && commands.isEmpty }
            commands.append(SimpleCommand(words: words, after: after))
            words = []
            after = joiner
            return true
        }
        func at(_ index: Int) -> Unicode.Scalar? {
            index >= 0 && index < chars.count ? chars[index] : nil
        }
        func indexOf(_ c: Unicode.Scalar, from start: Int) -> Int {
            var j = start
            while j < chars.count {
                if chars[j] == c { return j }
                j += 1
            }
            return -1
        }

        var i = 0
        scan: while i < chars.count {
            defer { i += 1 }
            let c = chars[i]
            let next = at(i + 1)
            switch c {
            case "'":
                let close = indexOf("'", from: i + 1)
                if close < 0 { return nil }
                word.append(contentsOf: chars[(i + 1)..<close])
                inWord = true
                i = close
            case "\"":
                var j = i + 1
                while j < chars.count, chars[j] != "\"" {
                    let d = chars[j]
                    if d == "`" || (d == "$" && at(j + 1) == "(") { return nil }
                    if d == "\\", j + 1 < chars.count { j += 1 }
                    word.append(chars[j])
                    j += 1
                }
                if j >= chars.count { return nil }
                inWord = true
                i = j
            case "\\":
                if next == "\n" {
                    i += 1
                } else if let next {
                    word.append(next)
                    inWord = true
                    i += 1
                }
            case "`", "(", ")":
                return nil
            case "$" where next == "(":
                return nil
            case "<" where next == "<":
                return nil
            case "#" where !inWord:
                // A comment runs to the end of its line.
                let end = indexOf("\n", from: i)
                if end < 0 { break scan }
                i = end - 1
            case "&":
                if next == "&" {
                    if !endCommand(.and) { return nil }
                    i += 1
                } else if next == ">" || at(i - 1) == ">" || at(i - 1) == "<" {
                    // `2>&1`, `>&2`, `&>log`: a redirection, part of the word.
                    word.append(c)
                    inWord = true
                } else {
                    // A command sent to the background: its status is not the
                    // line's.
                    return nil
                }
            case "|":
                if next == "|" {
                    if !endCommand(.or) { return nil }
                    i += 1
                } else {
                    if !endCommand(.pipe) { return nil }
                    if next == "&" { i += 1 }
                }
            case ";":
                if next == ";" { return nil }
                if !endCommand(.semicolon) { return nil }
            case "\n":
                endWord()
                if !words.isEmpty, !endCommand(.semicolon) { return nil }
            case " ", "\t":
                endWord()
            // A `{ …; }` group; `{a,b}` and `${x}` are words. (`where` binds
            // to a case's last pattern only, so both braces sit in the guard.)
            case _ where (c == "{" || c == "}") && !inWord && (next.map(JS.isWhitespace) ?? true):
                return nil
            default:
                word.append(c)
                inWord = true
            }
        }
        endWord()
        if !words.isEmpty {
            commands.append(SimpleCommand(words: words, after: after))
        } else if let after, after != .semicolon {
            return nil
        }
        return commands.isEmpty ? nil : commands
    }

    private static let assignmentRE = JS.regex(#"^[A-Za-z_][A-Za-z0-9_]*="#)
    /// A redirection operator alone (its target is the next word).
    private static let redirectOpRE = JS.regex(#"^(?:[0-9]*|&)(?:>>?|<|>&|<&|>\|)\z"#)
    /// A redirection with its target attached.
    private static let redirectRE = JS.regex(#"^(?:[0-9]*|&)(?:>>?|<|>&|<&|>\|)\#(JS.S)"#)
    private static let printFlagRE = JS.regex(#"^-[vV]\z"#)

    private static func isAssignment(_ word: String) -> Bool { JS.test(assignmentRE, word) }

    /// The words a command runs with: assignments, redirections and
    /// pass-through wrappers (`env`, `command`, `time`, `timeout 30`…) set
    /// aside; the program named by its basename. Nil for a command this reader
    /// does not follow.
    private static func argv(_ command: SimpleCommand) -> [String]? {
        var words: [String] = []
        var i = 0
        while i < command.words.count {
            defer { i += 1 }
            let word = command.words[i]
            if JS.test(redirectOpRE, word) {
                i += 1
                continue
            }
            if JS.test(redirectRE, word) { continue }
            words.append(word)
        }
        var at = 0
        while true {
            while at < words.count, isAssignment(words[at]) { at += 1 }
            guard at < words.count else { return nil }
            let head = words[at]
            if head == "!" || head == "set" || head == "eval" { return nil }
            if head == "env" {
                at += 1
                while at < words.count, JS.startsWith(words[at], "-") { at += 1 }
                continue
            }
            if head == "time" || head == "nohup" || head == "builtin" {
                at += 1
                while at < words.count, words[at] == "-p" { at += 1 }
                continue
            }
            if head == "command", !JS.test(printFlagRE, at + 1 < words.count ? words[at + 1] : "") {
                at += 1
                continue
            }
            break
        }
        var rest = Array(words[at...])
        rest[0] = basename(rest[0])
        return rest
    }

    /// `word.replace(/^.*\//, "")`: through the last `/` before the first line
    /// break (JavaScript's `.` does not cross one).
    private static func basename(_ word: String) -> String {
        let scalars = word.unicodeScalars
        let lineEnd = scalars.firstIndex { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }
            ?? scalars.endIndex
        guard let slash = scalars[..<lineEnd].lastIndex(of: "/") else { return word }
        return String(scalars[scalars.index(after: slash)...])
    }

    /// What a simple command's own name is, once its words are read.
    private static func nameOf(_ command: SimpleCommand) -> String? {
        argv(command)?.first
    }

    /// Commands whose status is 0 whenever they run — `printf` is not one: a
    /// bad number in its arguments fails it.
    private static let neverFailsNames: Set<String> = ["echo", "true", ":"]

    /// Whether a command redirects anything: its error can go unprinted, its
    /// own output can fail to land.
    private static func redirects(_ command: SimpleCommand) -> Bool {
        command.words.contains { JS.test(redirectOpRE, $0) || JS.test(redirectRE, $0) }
    }

    private static func neverFails(_ command: SimpleCommand) -> Bool {
        neverFailsNames.contains(nameOf(command) ?? "") && !redirects(command)
    }

    /// Builtins that end the line, or hand it to something else, before the
    /// commands after them run.
    private static let endsLine: Set<String> = ["exit", "return", "exec", "logout", "source", "."]

    /// What may run ahead of the deciding command with `&&`: setup that says
    /// so when it fails, which an answer's quiet output then rules out.
    private static let setupNames: Set<String> = ["cd", "pushd", "export"]

    /// The words of the command whose status the line returns, or nil when the
    /// line could have taken it from somewhere this reader cannot tell.
    private static func decidingCommand(_ commands: [SimpleCommand]) -> (words: [String], afterSetup: Bool)? {
        // `set -e` and `pipefail` change whose status a list or a pipeline
        // returns; an `exit` (or a sourced script that may hold one) can end
        // the line before its last command runs.
        for command in commands {
            let first = command.words.first { !isAssignment($0) } ?? ""
            if first == "set" || endsLine.contains(first) { return nil }
        }
        var k = commands.count - 1
        // `… && echo found`: the echo cannot fail, so a non-zero status came
        // from the command it was waiting on.
        while k > 0, neverFails(commands[k]) {
            if commands[k].after != .and { return nil }
            k -= 1
        }
        if neverFailsNames.contains(nameOf(commands[k]) ?? "") { return nil }
        // A pipeline's status is its last command's; what ran ahead of the
        // pipeline with `&&` could have stopped the line before it ran at all.
        var start = k
        while start > 0, commands[start].after == .pipe { start -= 1 }
        var afterSetup = false
        var i = start
        while i > 0, commands[i].after == .and {
            let setup = commands[i - 1]
            // Setup whose complaint is sent away fails without a word.
            if !setupNames.contains(nameOf(setup) ?? "") || redirects(setup) { return nil }
            afterSetup = true
            i -= 1
        }
        guard let words = argv(commands[k]) else { return nil }
        return (words, afterSetup)
    }

    // MARK: - Reading what it printed

    /// `zsh:1: no matches found: *.rs`, `bash: foo: command not found`: the
    /// shell's own complaint, which no answer prints.
    private static let shellComplaintRE = JS.regex(
        #"^(?:\(eval\)|(?:[A-Za-z0-9_./\-]*/)?-?(?:ba|z|da|k)?sh)(?::\#(JS.s)*(?:line\#(JS.s)+)?[0-9]+)?:"#)
    private static let noSuchFileRE = JS.regex("no such file or directory", ignoreCase: true)
    /// `\b` is ASCII in JavaScript: spelled as look-arounds.
    private static let notFoundRE = JS.regex(
        #"(?<![A-Za-z0-9_])not found(?![A-Za-z0-9_])|^which: no \#(JS.S)"#, ignoreCase: true)
    private static let timedOutRE = JS.regex(#"(?<![A-Za-z0-9_])timed out(?![A-Za-z0-9_])"#, ignoreCase: true)
    /// `grep -c` with nothing matched still prints its counts: `0`, `f.ts:0`.
    private static let zeroCountRE = JS.regex(#"^(?:\#(JS.dot)*:)?0\z"#)
    /// git's own diagnostics: `error: Could not access 'x'`, `fatal: …`.
    private static let gitDiagnosticRE = JS.regex(#"^(?:error|fatal|usage|warning):"#, ignoreCase: true)
    /// The one sed script that only prints: a line or a range of them.
    private static let sedPrintRE = JS.regex(#"^(?:[0-9]+|\$)(?:,(?:[0-9]+|\$))?p\z"#)

    /// The agents' framing around what a command printed: Claude Code's `Exit
    /// code 1` (and the fence it may wrap the result in), OpenCode 2's closing
    /// notice (`Exited with code 1` / `Killed by SIGTERM` through 2.2.6, `Exit
    /// code: 1` / `Exit code: 143 (SIGTERM)` / `Exit code: unknown` from
    /// 2.2.7), codex's `Wall time: …` lines, the backend's `[terminal exited: …]`.
    private static let framingRE = JS.regex(
        #"^(?:exit code[:\#(JS.wsClass)]\#(JS.s)*(?:-?[0-9]+(?:\#(JS.s)+\(SIG[A-Z0-9]+\))?|unknown)\z|exited with code\#(JS.s)+-?[0-9]+\z|killed by\#(JS.s)+SIG[A-Z0-9]+\z|\[terminal exited:|```)"#,
        ignoreCase: true)

    /// The lines the command printed, the framing left out.
    private static func printedLines(_ output: String) -> [String] {
        JS.split(output, "\n").map(JS.trim).filter { line in
            !line.isEmpty && !ActivityCommand.isCliMetaLine(line) && !JS.test(framingRE, line)
        }
    }

    // MARK: - What each command's exit 1 answers

    private static let searches: Set<String> = [
        "grep", "egrep", "fgrep", "zgrep", "rg", "ag", "ack", "pgrep", "pidof",
        // Nothing has the file or port open.
        "lsof",
    ]
    private static let tests: Set<String> = ["test", "[", "[["]
    private static let lookups: Set<String> = ["which", "type", "whereis"]
    /// Silent when what they look up is not set.
    private static let quietLookups: Set<String> = ["printenv"]
    /// Commands that only look at a path: a missing one is not there to see.
    private static let looks: Set<String> = [
        "ls", "stat", "cat", "head", "tail", "wc", "file", "nl", "readlink", "realpath", "du", "sed",
    ]

    private static let gitDirFlagRE = JS.regex(#"^-[Cc]\z"#)

    /// Git's global options ahead of its subcommand, and how many words each
    /// takes.
    private static func gitSubcommand(_ words: [String]) -> (name: String, args: [String]) {
        var at = 1
        while at < words.count, JS.startsWith(words[at], "-") {
            at += JS.test(gitDirFlagRE, words[at]) ? 2 : 1
        }
        let name = at < words.count ? words[at] : ""
        let args = at + 1 < words.count ? Array(words[(at + 1)...]) : []
        return (name, args)
    }

    /// `sed -n '1,40p' file…`: quiet, one script that prints a line or a
    /// range, nothing else that could make it write.
    private static func printsLines(_ words: [String]) -> Bool {
        let tail = words.dropFirst()
        let options = tail.filter { JS.startsWith($0, "-") }
        let operands = tail.filter { !JS.startsWith($0, "-") }
        return !options.isEmpty
            && options.allSatisfy { $0 == "-n" || $0 == "--quiet" }
            && operands.count >= 2
            && JS.test(sedPrintRE, operands[0])
    }

    private static let gitDiffAnswerFlagRE = JS.regex(#"^--(?:exit-code|quiet|no-index)\z"#)
    private static let gitVerifyFlagRE = JS.regex(#"^--verify\z"#)
    private static let gitIsAncestorFlagRE = JS.regex(#"^--is-ancestor\z"#)

    /// What git's exit 1 answers, by subcommand.
    private static func gitAnswer(_ sub: (name: String, args: [String]), quiet: Bool, complaint: Bool) -> ExitMeaning? {
        func has(_ re: NSRegularExpression) -> Bool { sub.args.contains { JS.test(re, $0) } }
        switch sub.name {
        // No path given is ignored.
        case "grep", "check-ignore":
            return quiet ? .noMatch : nil
        case "diff":
            return has(gitDiffAnswerFlagRE) && !complaint ? .differs : nil
        // A key, a ref that is not there.
        case "config", "show-ref":
            return quiet ? .notFound : nil
        case "rev-parse":
            return quiet && has(gitVerifyFlagRE) ? .notFound : nil
        case "merge-base":
            return quiet && has(gitIsAncestorFlagRE) ? .false : nil
        default:
            return nil
        }
    }

    private static func answerOf(_ words: [String], code: Int, lines: [String]) -> ExitMeaning? {
        let name = words[0]
        let quiet = lines.isEmpty
        // The shell's own complaint — a glob that matched nothing, a redirect
        // to a missing folder — exits 1 too, before or around the command.
        let complaint = lines.contains { JS.test(shellComplaintRE, $0) }
        if code == 1 {
            if searches.contains(name) {
                return quiet || lines.allSatisfy({ JS.test(zeroCountRE, $0) }) ? .noMatch : nil
            }
            if tests.contains(name) { return quiet ? .false : nil }
            if name == "diff" || name == "cmp" { return complaint ? nil : .differs }
            if name == "git" {
                let diagnosed = lines.contains { JS.test(gitDiagnosticRE, $0) }
                return gitAnswer(gitSubcommand(words), quiet: quiet, complaint: complaint || diagnosed)
            }
            if quietLookups.contains(name) { return quiet ? .notFound : nil }
            // A shell's builtin says it with the shell's prefix: `bash: type:
            // x: not found`.
            if lookups.contains(name) || (name == "command" && JS.test(printFlagRE, words.count > 1 ? words[1] : "")) {
                return lines.allSatisfy({ JS.test(notFoundRE, $0) }) ? .notFound : nil
            }
        }
        if code == 1 || code == 2, looks.contains(name), !complaint {
            // sed can write (`-i`, a `w` command): only `sed -n '1,40p' file`
            // looks.
            if name == "sed", !printsLines(words) { return nil }
            return !quiet && lines.allSatisfy({ JS.test(noSuchFileRE, $0) }) ? .notFound : nil
        }
        return nil
    }

    /// What a command's non-zero exit says: an answer (the command did what
    /// it was asked and the answer is "no"), a failure the code names, or nil
    /// — a plain failure.
    static func readCommandExit(_ commandLine: String, exit: CommandExit, output: String) -> ExitMeaning? {
        guard let code = exit.code, code != 0 else { return nil }
        let lines = printedLines(output)
        let deciding = splitCommandLine(commandLine).flatMap(decidingCommand)
        if let deciding, let answer = answerOf(deciding.words, code: code, lines: lines) {
            // Setup chained ahead with `&&` says so when it fails: past it,
            // only an answer that printed nothing is surely the deciding
            // command's.
            if !deciding.afterSetup || lines.isEmpty { return answer }
        }
        if code == 127 { return .commandNotFound }
        if code == 126 { return .notExecutable }
        let timeout = deciding?.words.first
        if (code == 124 && (timeout == "timeout" || timeout == "gtimeout"))
            || ((code == 124 || code == 143) && lines.contains { JS.test(timedOutRE, $0) }) {
            return .timedOut
        }
        return nil
    }
}
