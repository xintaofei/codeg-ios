import Foundation

/// A codex shell command read the way codex reads it (codex `parse_command`),
/// for the copy of the call its transcript keeps.
///
/// Live, codex-acp announces a command that codex takes for a file read, a
/// listing or a search as that action (`CodexCommandAction`): "Read file '…'",
/// "List files in '…'". The transcript keeps only `exec_command` and the command
/// line, so the same reply read back from it showed its steps as commands —
/// "Ran 2 commands" where it had streamed as "Read 2 files". This gives the
/// saved call the identity the live one had.
///
/// Only for a single plain command, by codex's own rules for it: `cat`,
/// `head`/`tail`, `sed -n`, `nl`, `bat`, `less`, `more` read; `ls`, `eza`,
/// `tree`, `du`, `rg --files`, `git ls-files` list; `rg`, `grep`, `git grep`
/// search. Anything with a pipe, a connector, a redirect, a substitution or a
/// glob stays a command here, including some codex does read (`cd x && cat y`,
/// `cat y | head`) — those keep the mismatch rather than guess at more of
/// codex's grammar.
///
/// Port of Android `CodexShellAction.kt`. Strings are walked as Unicode
/// scalars, never `Character`s: a `\r\n` is ONE `Character` in Swift, so a
/// grapheme walk would not see the line break the Kotlin rejects.
enum CodexShellAction {

    /// The tool identity the live call had, and the input that names its target.
    static func resolve(_ command: String) -> CodexCommandAction.Resolved? {
        guard let tokens = split(command), let head = tokens.first else { return nil }
        let tail = Array(tokens.dropFirst())
        switch head {
        case "ls": return listFiles(firstOperand(tail, lsFlagsWithValues))
        case "eza", "exa": return listFiles(firstOperand(tail, ezaFlagsWithValues))
        case "tree": return listFiles(firstOperand(tail, treeFlagsWithValues))
        case "du": return listFiles(firstOperand(tail, duFlagsWithValues))
        case "rg", "rga", "ripgrep-all": return ripgrep(tail)
        case "git":
            switch tail.first {
            case "grep"?: return grepLike(Array(tail.dropFirst()))
            case "ls-files"?: return listFiles(firstOperand(Array(tail.dropFirst()), gitLsFilesFlagsWithValues))
            default: return nil
            }
        case "grep", "egrep", "fgrep": return grepLike(tail)
        case "cat", "more": return singleOperand(tail, []).map(readFile)
        case "bat", "batcat": return singleOperand(tail, batFlagsWithValues).map(readFile)
        case "less": return singleOperand(tail, lessFlagsWithValues).map(readFile)
        case "head": return headTailPath(tail, allowPlus: false).map(readFile)
        case "tail": return headTailPath(tail, allowPlus: true).map(readFile)
        case "nl": return skipFlagValues(tail, nlFlagsWithValues).first(where: { !isFlag($0) }).map(readFile)
        case "sed": return sedReadPath(tail).map(readFile)
        default: return nil
        }
    }

    /// codex's shell tool, by the name its transcript keeps.
    static func isShellName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n == "exec_command" || n == "functions.exec_command"
    }

    /// The command line a saved `exec_command` ran: its text, or the `cmd` of a
    /// JSON input.
    static func commandOf(input: String?, parsed: [String: Any]?) -> String? {
        guard let args = ToolDerive.effectiveArgs(parsed) else {
            guard let input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return input
        }
        for key in ["cmd", "command"] {
            if let value = args[key] as? String { return value }
        }
        return nil
    }

    /// Whether a saved search's failure is rg / grep's exit 1 with nothing
    /// printed — "no matches". codex reports it as a failed call; the live copy
    /// settles as a success (`GrepNoMatch`), and so does the saved one. The
    /// exit is the one the call recorded, else the `Process exited with code`
    /// line of codex's framing, which the server keeps when the body is empty.
    static func isNoMatchResult(output: String?, exitCode: Int?) -> Bool {
        guard let code = exitCode ?? ActivityCommand.extractCommandExit(output)?.code, code == 1 else {
            return false
        }
        let printed = output.map(ActivityCommand.normalizeCommandOutput) ?? ""
        return printed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private static func readFile(_ path: String) -> CodexCommandAction.Resolved {
        CodexCommandAction.Resolved(name: "read", input: CodexCommandAction.encode(["file_path": path]))
    }

    private static func listFiles(_ path: String?) -> CodexCommandAction.Resolved {
        var args: [String: String] = [:]
        if let path { args["path"] = shortDisplayPath(path) }
        return CodexCommandAction.Resolved(name: "glob", input: CodexCommandAction.encode(args))
    }

    private static func search(_ query: String?, _ path: String?) -> CodexCommandAction.Resolved {
        var args: [String: String] = [:]
        if let query { args["pattern"] = query }
        if let path { args["path"] = shortDisplayPath(path) }
        return CodexCommandAction.Resolved(name: "grep", input: CodexCommandAction.encode(args))
    }

    private static func ripgrep(_ args: [String]) -> CodexCommandAction.Resolved {
        let nonFlags = skipFlagValues(args, rgFlagsWithValues).filter { !isFlag($0) }
        if args.contains("--files") { return listFiles(nonFlags.first) }
        return search(nonFlags.first, nonFlags.count > 1 ? nonFlags[1] : nil)
    }

    private static func grepLike(_ args: [String]) -> CodexCommandAction.Resolved {
        var operands: [String] = []
        var pattern: String?
        var afterDoubleDash = false
        var i = 0
        while i < args.count {
            let arg = args[i]
            i += 1
            if afterDoubleDash {
                operands.append(arg)
                continue
            }
            switch arg {
            case "--":
                afterDoubleDash = true
            case "-e", "--regexp", "-f", "--file":
                let value = i < args.count ? args[i] : nil
                i += 1
                if pattern == nil { pattern = value }
            case "-m", "--max-count", "-C", "--context", "-A", "--after-context", "-B", "--before-context":
                i += 1
            default:
                if !isFlag(arg) { operands.append(arg) }
            }
        }
        let query = pattern ?? operands.first
        let pathIndex = pattern != nil ? 0 : 1
        return search(query, pathIndex < operands.count ? operands[pathIndex] : nil)
    }

    /// `head -n 50 f`, `head -n50 f` (`tail` also `-n +10`), or one bare file;
    /// not `head -5 f`.
    private static func headTailPath(_ args: [String], allowPlus: Bool) -> String? {
        func count(_ value: Substring.UnicodeScalarView) -> Bool {
            let digits = allowPlus && value.first == "+" ? value.dropFirst() : value
            return !digits.isEmpty && digits.allSatisfy(isAsciiDigit)
        }
        let first = args.first
        let validN: Bool
        if let first, first == "-n" {
            validN = args.count > 1 && count(Substring(args[1]).unicodeScalars)
        } else if let first, startsWith(first, "-n") {
            validN = count(Substring(first).unicodeScalars.dropFirst(2))
        } else {
            validN = false
        }
        if validN {
            let candidates = first == "-n" ? args.dropFirst(2) : args.dropFirst(1)
            if let path = candidates.first(where: { !isFlag($0) }) { return path }
        }
        guard args.count == 1, !isFlag(args[0]) else { return nil }
        return args[0]
    }

    private static func sedReadPath(_ args: [String]) -> String? {
        if sedEditsInPlace(args) || !args.contains("-n") { return nil }
        var hasRange = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-e", "--expression":
                if isSedRange(i + 1 < args.count ? args[i + 1] : nil) { hasRange = true }
                i += 2
            case "-f", "--file":
                i += 2
            default:
                i += 1
            }
        }
        if !hasRange { hasRange = args.contains { !isFlag($0) && isSedRange($0) } }
        if !hasRange { return nil }
        let nonFlags = skipFlagValues(args, sedFlagsWithValues).filter { !isFlag($0) }
        guard let first = nonFlags.first else { return nil }
        if isSedRange(first) { return nonFlags.count > 1 ? nonFlags[1] : nil }
        return first
    }

    /// `Np` or `N,Mp`.
    private static func isSedRange(_ arg: String?) -> Bool {
        guard let scalars = arg?.unicodeScalars, scalars.last == "p" else { return false }
        let parts = scalars.dropLast().split(separator: ",", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count)
            && parts.allSatisfy { part in !part.isEmpty && part.allSatisfy(isAsciiDigit) }
    }

    private static func sedEditsInPlace(_ args: [String]) -> Bool {
        var i = 0
        while i < args.count {
            let token = args[i]
            i += 1
            if token == "--" { return false }
            if ["-e", "-f", "--expression", "--file"].contains(token) {
                i += 1
            } else if token == "--in-place" || startsWith(token, "--in-place=") {
                return true
            } else if startsWith(token, "--") {
                continue
            } else if isFlag(token) {
                let options = Array(token.unicodeScalars.dropFirst())
                for (index, option) in options.enumerated() {
                    if option == "i" { return true }
                    if option == "e" || option == "f" {
                        if index == options.count - 1 { i += 1 }
                        break
                    }
                }
            }
        }
        return false
    }

    // MARK: - Words

    private static func skipFlagValues(_ args: [String], _ flagsWithValues: Set<String>) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" {
                out.append(contentsOf: args[(i + 1)...])
                return out
            } else if startsWith(arg, "--"), arg.unicodeScalars.contains("=") {
                // `--flag=value`: the value rides along.
            } else if flagsWithValues.contains(arg) {
                if i + 1 < args.count { i += 1 }
            } else {
                out.append(arg)
            }
            i += 1
        }
        return out
    }

    private static func operands(_ args: [String], _ flagsWithValues: Set<String>) -> [String] {
        var out: [String] = []
        var afterDoubleDash = false
        var i = 0
        while i < args.count {
            let arg = args[i]
            if afterDoubleDash {
                out.append(arg)
            } else if arg == "--" {
                afterDoubleDash = true
            } else if startsWith(arg, "--"), arg.unicodeScalars.contains("=") {
                // `--flag=value`
            } else if flagsWithValues.contains(arg) {
                if i + 1 < args.count { i += 1 }
            } else if !isFlag(arg) {
                out.append(arg)
            }
            i += 1
        }
        return out
    }

    private static func firstOperand(_ args: [String], _ flagsWithValues: Set<String>) -> String? {
        operands(args, flagsWithValues).first
    }

    /// The one operand, or nil for none or several (`cat a b` is no single read).
    private static func singleOperand(_ args: [String], _ flagsWithValues: Set<String>) -> String? {
        let all = operands(args, flagsWithValues)
        return all.count == 1 ? all[0] : nil
    }

    private static func isAsciiDigit(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) }

    /// Kotlin `startsWith("-")`, by scalar: `hasPrefix` compares `Character`s,
    /// and a combining mark after the dash would make it a different one.
    private static func isFlag(_ s: String) -> Bool { s.unicodeScalars.first == "-" }

    private static func startsWith(_ s: String, _ prefix: String) -> Bool {
        s.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    /// The path's last telling component, as codex shows it: `webview/src` →
    /// `webview`.
    static func shortDisplayPath(_ path: String) -> String {
        var scalars = Array(path.replacingOccurrences(of: "\\", with: "/").unicodeScalars)
        while scalars.last == "/" { scalars.removeLast() }
        let trimmed = String(String.UnicodeScalarView(scalars))
        return trimmed.components(separatedBy: "/").reversed()
            .first(where: { !$0.isEmpty && !untellingDirs.contains($0) }) ?? trimmed
    }

    /// Shell words, or nil for a line that is more than one plain command: an
    /// unquoted operator, redirect, substitution, glob or line break, or an
    /// unclosed quote.
    static func split(_ line: String) -> [String]? {
        let s = Array(line.unicodeScalars)
        var words: [String] = []
        var word = String.UnicodeScalarView()
        var inWord = false
        var i = 0
        while i < s.count {
            let c = s[i]
            switch c {
            case "'":
                guard let end = s[(i + 1)...].firstIndex(of: "'") else { return nil }
                word.append(contentsOf: s[(i + 1)..<end])
                inWord = true
                i = end
            case "\"":
                var j = i + 1
                while true {
                    if j >= s.count { return nil }
                    let d = s[j]
                    if d == "\"" { break }
                    if d == "$" || d == "`" { return nil }
                    if d == "\\", j + 1 < s.count, doubleQuoteEscapes.contains(s[j + 1]) {
                        word.append(s[j + 1])
                        j += 2
                        continue
                    }
                    word.append(d)
                    j += 1
                }
                inWord = true
                i = j
            case "\\":
                if i + 1 >= s.count || s[i + 1] == "\n" { return nil }
                word.append(s[i + 1])
                inWord = true
                i += 1
            case " ", "\t":
                if inWord {
                    words.append(String(word))
                    word = String.UnicodeScalarView()
                    inWord = false
                }
            default:
                if shellSpecial.contains(c) { return nil }
                word.append(c)
                inWord = true
            }
            i += 1
        }
        if inWord { words.append(String(word)) }
        return words.isEmpty ? nil : words
    }

    // MARK: - Tables

    private static let shellSpecial = Set("|&;<>()$`*?[]{}~#!\n\r".unicodeScalars)
    /// What a backslash escapes inside double quotes.
    private static let doubleQuoteEscapes = Set("\"\\$`".unicodeScalars)
    private static let untellingDirs: Set<String> = ["build", "dist", "node_modules", "src"]
    private static let lsFlagsWithValues: Set<String> = [
        "-I", "-w", "--block-size", "--format", "--time-style", "--color", "--quoting-style",
    ]
    private static let ezaFlagsWithValues: Set<String> = [
        "-I", "--ignore-glob", "--color", "--sort", "--time-style", "--time",
    ]
    private static let treeFlagsWithValues: Set<String> = ["-L", "-P", "-I", "--charset", "--filelimit", "--sort"]
    private static let duFlagsWithValues: Set<String> = [
        "-d", "--max-depth", "-B", "--block-size", "--exclude", "--time-style",
    ]
    private static let rgFlagsWithValues: Set<String> = [
        "-g", "--glob", "--iglob", "-t", "--type", "--type-add", "--type-not", "-m", "--max-count",
        "-A", "-B", "-C", "--context", "--max-depth",
    ]
    private static let gitLsFilesFlagsWithValues: Set<String> = ["--exclude", "--exclude-from", "--pathspec-from-file"]
    private static let batFlagsWithValues: Set<String> = [
        "--theme", "--language", "--style", "--terminal-width", "--tabs", "--line-range", "--map-syntax",
    ]
    private static let lessFlagsWithValues: Set<String> = [
        "-p", "-P", "-x", "-y", "-z", "-j", "--pattern", "--prompt", "--tabs", "--shift", "--jump-target",
    ]
    private static let nlFlagsWithValues: Set<String> = ["-s", "-w", "-v", "-i", "-b"]
    private static let sedFlagsWithValues: Set<String> = ["-e", "-f", "--expression", "--file"]
}
