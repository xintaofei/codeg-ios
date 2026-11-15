import Foundation
import Testing
@testable import Codeg

/// codex's own reading of a shell command — Android `CodexShellActionTest.kt`
/// (7526a6b), case for case. Inputs are the JSON text `CodexCommandAction.encode`
/// writes: keys sorted, so a search reads `{"path":…,"pattern":…}` where
/// Android's insertion order has the pattern first.
struct CodexShellActionTests {
    private struct Action: Equatable, CustomStringConvertible {
        let name: String
        let input: String
        init(_ name: String, _ input: String) { self.name = name; self.input = input }
        var description: String { "\(name) \(input)" }
    }

    private func resolved(_ command: String) -> Action? {
        CodexShellAction.resolve(command).map { Action($0.name, $0.input) }
    }

    @Test("reads codex takes for reads")
    func readsCodexTakesForReads() {
        #expect(resolved("cat /root/a/SKILL.md") == Action("read", #"{"file_path":"/root/a/SKILL.md"}"#))
        #expect(resolved("head -n 35 README.md") == Action("read", #"{"file_path":"README.md"}"#))
        #expect(resolved("head -n35 README.md") == Action("read", #"{"file_path":"README.md"}"#))
        #expect(resolved("tail -n +10 log.txt") == Action("read", #"{"file_path":"log.txt"}"#))
        #expect(resolved("sed -n '1,120p' Main.kt") == Action("read", #"{"file_path":"Main.kt"}"#))
        #expect(resolved("nl -ba Main.kt") == Action("read", #"{"file_path":"Main.kt"}"#))
        #expect(resolved(#"cat "my file.md""#) == Action("read", #"{"file_path":"my file.md"}"#))
    }

    @Test("listings and searches")
    func listingsAndSearches() {
        #expect(resolved("ls") == Action("glob", "{}"))
        #expect(resolved("ls src") == Action("glob", #"{"path":"src"}"#))
        #expect(resolved("ls -la /root/codeg/src/app/") == Action("glob", #"{"path":"app"}"#))
        #expect(resolved("rg --files lib") == Action("glob", #"{"path":"lib"}"#))
        #expect(resolved("rg -n TODO src/lib") == Action("grep", #"{"path":"lib","pattern":"TODO"}"#))
        #expect(resolved("grep -rn 'a b' .") == Action("grep", #"{"path":".","pattern":"a b"}"#))
        #expect(resolved("git grep -e x") == Action("grep", #"{"pattern":"x"}"#))
    }

    @Test("what codex leaves a command stays one")
    func whatCodexLeavesACommandStaysOne() {
        // `head -5` isn't a form codex reads (live it streamed as a command too).
        #expect(resolved("head -5 README.md") == nil)
        #expect(resolved("git log --oneline -3") == nil)
        #expect(resolved("wc -l package.json") == nil)
        #expect(resolved("cat a.md b.md") == nil)
        #expect(resolved("sed -i 's/a/b/' f.txt") == nil)
        #expect(resolved("sed 's/a/b/' f.txt") == nil)
        // More than one plain command: not guessed at.
        #expect(resolved("cat a | head -n 5") == nil)
        #expect(resolved("cd app && cat b") == nil)
        #expect(resolved("cat *.md") == nil)
        #expect(resolved("cat $HOME/x") == nil)
        #expect(resolved("cat 'unclosed") == nil)
        #expect(resolved("") == nil)
    }

    @Test("codex shortens a listed path the way it shows it")
    func codexShortensAListedPathTheWayItShowsIt() {
        #expect(CodexShellAction.shortDisplayPath("webview/src") == "webview")
        #expect(CodexShellAction.shortDisplayPath("packages/app/node_modules/") == "app")
        #expect(CodexShellAction.shortDisplayPath("src") == "src")
    }

    // MARK: - iOS-only

    @Test("splits shell words by quotes and escapes, and refuses a line break")
    func splitsShellWords() {
        #expect(CodexShellAction.split(#"cat a\ b.md"#) == ["cat", "a b.md"])
        #expect(CodexShellAction.split(#"cat "a \"b\".md" 'c d'"#) == ["cat", #"a "b".md"#, "c d"])
        // `\r\n` is one `Character` in Swift; the scalar walk still sees both.
        #expect(CodexShellAction.split("cat a.md\r\n") == nil)
        #expect(CodexShellAction.split("cat a.md\ncat b.md") == nil)
        #expect(resolved("cat a.md\r\n") == nil)
    }

    @Test("a saved command line is its text, or the cmd of a JSON input")
    func aSavedCommandLineIsItsTextOrTheCmdOfAJSONInput() {
        func commandOf(_ input: String?) -> String? {
            CodexShellAction.commandOf(input: input, parsed: ToolDerive.parseJSON(input))
        }
        #expect(commandOf("cat a.md") == "cat a.md")
        #expect(commandOf(#"{"cmd":"ls src"}"#) == "ls src")
        #expect(commandOf(#"{"cmd":["ls"]}"#) == nil)
        #expect(commandOf("  ") == nil)
        #expect(commandOf(nil) == nil)
    }
}

/// Android `CodexCommandActionTest.kt`'s read-title cases (7526a6b).
struct CodexCommandActionReadTitleTests {
    @Test("a read title yields the file it read, as the card's input")
    func aReadTitleYieldsTheFileItRead() {
        let read = CodexCommandAction.resolve(title: "Read file '/root/app/src/main.kt'")
        #expect(read?.name == "read")
        #expect(read?.input == #"{"file_path":"/root/app/src/main.kt"}"#)
    }

    @Test("leaves a joined, an empty and an unquoted read title alone")
    func leavesOtherReadTitlesAlone() {
        #expect(CodexCommandAction.readFile(title: "Read file 'a', Read file 'b'") == nil)
        #expect(CodexCommandAction.readFile(title: "Read file ''") == nil)
        #expect(CodexCommandAction.readFile(title: "Read SKILL.md") == nil)
        #expect(CodexCommandAction.readFile(title: nil) == nil)
        #expect(CodexCommandAction.resolve(title: "Read file 'a', Read file 'b'")?.name == nil)
    }
}

/// The saved call drawn as the live one was — the rest of Android
/// `CodexShellActionTest.kt`, through iOS's two adapters.
@MainActor
struct CodexSavedCommandIdentityTests {
    /// A live codex-acp call, as the stream delivers it: a title, a kind, no input.
    private func live(_ title: String, _ kind: String, rawInput: String? = nil) -> ToolCallVM? {
        let turn = LiveTurn()
        turn.upsertToolCall(id: "c1", title: title, kind: kind, status: "completed",
                            rawInput: rawInput, rawOutput: "out", content: nil)
        return Self.onlyCall(MessageRender.adaptLive(turn))
    }

    /// The transcript's copy: `exec_command` and the bare command line.
    private func saved(_ command: String, id: String = "c1", output: String? = "out",
                       isError: Bool = false) -> ToolCallVM? {
        let turn = MessageTurn(id: "saved-\(id)-\(command)", role: .assistant, blocks: [
            .toolUse(id: id, name: "exec_command", inputPreview: command, status: .unknown, meta: nil),
            .toolResult(id: id, outputPreview: output, isError: isError, agentStats: nil),
        ], timestamp: Date())
        return Self.onlyCall(MessageRender.adaptTurn(turn))
    }

    private static func onlyCall(_ parts: [RenderPart]) -> ToolCallVM? {
        guard parts.count == 1, case .tool(let vm) = parts[0] else { return nil }
        return vm
    }

    /// Everything a card and an activity row are drawn from.
    private func identity(_ vm: ToolCallVM?) -> [String]? {
        guard let vm else { return nil }
        let tool = DescribeToolCall.describe(vm)
        return [vm.rawName, vm.input ?? "nil", vm.displayTitle, "\(vm.bucket)", vm.toolName,
                tool.kind.rawValue, tool.target?.text ?? "nil", tool.target?.path ?? "nil"]
    }

    @Test("a saved codex command reads back as the action it streamed as")
    func aSavedCodexCommandReadsBackAsTheActionItStreamedAs() {
        #expect(identity(live("Read file '/root/a/SKILL.md'", "read")) == identity(saved("cat /root/a/SKILL.md")))
        #expect(identity(live("List files in 'src'", "search")) == identity(saved("ls src")))
        #expect(identity(live("List files", "search")) == identity(saved("ls")))
        #expect(identity(live("Search for 'TODO' in lib", "search")) == identity(saved("rg TODO src/lib")))
    }

    @Test("a saved reply's reads count as files read, not as commands run")
    func aSavedReplysReadsCountAsFilesRead() {
        let steps = [saved("cat /r/a.md", id: "c1"), saved("sed -n '1,40p' /r/b.md", id: "c2")]
            .compactMap { $0 }
            .map { vm in
                ActivityStep.tool(ActivityToolStep(key: "tool:\(vm.id)", call: vm,
                                                   tool: DescribeToolCall.describe(vm), laterPolls: nil))
            }
        let summary = ActivitySummarize.summarize(steps)
        #expect(summary.counts.readFiles == 2)
        #expect(summary.counts.commands == 0)
    }

    @Test("a saved command codex ran as a command keeps its command line")
    func aSavedCommandCodexRanAsACommandKeepsItsCommandLine() {
        let vm = saved("git log --oneline -3")
        #expect(vm?.rawName == "exec_command")
        #expect(vm?.input == "git log --oneline -3")
        #expect(vm?.displayTitle == "git log --oneline -3")
        let display = vm.flatMap { DescribeToolCall.describe($0).command?.display }
        #expect(display == "git log --oneline -3")
    }

    @Test("a live command titled by its own command line is titled by it once")
    func aLiveCommandTitledByItsOwnCommandLineIsTitledByItOnce() {
        let input = #"{"command":"git log --oneline -3"}"#
        #expect(live("git log --oneline -3", "execute", rawInput: input)?.displayTitle == "git log --oneline -3")
        // A kind that doesn't say "command" leaves the title to the generic
        // rule, which read "ls -la: ls -la".
        #expect(live("ls -la", "other", rawInput: #"{"command":"ls -la"}"#)?.displayTitle == "ls -la")
    }

    @Test("a live read carries its file as the card's input")
    func aLiveReadCarriesItsFileAsTheCardsInput() {
        let vm = live("Read file '/root/app/src/main.kt'", "read")
        #expect(vm?.rawName == "read")
        #expect(vm?.input == #"{"file_path":"/root/app/src/main.kt"}"#)
        #expect(vm?.bucket == .read)
        #expect(vm?.displayTitle == "Read src/main.kt")
        let tool = vm.map { DescribeToolCall.describe($0) }
        #expect(tool?.kind == .read)
        #expect(tool?.target?.path == "/root/app/src/main.kt")
    }

    /// codex's framing of an exit 1 that printed nothing, which the server
    /// keeps whole when the body under `Output:` is empty.
    private let emptyExitOne = "Chunk ID: 1a2b\nWall time: 0.0100 seconds\nProcess exited with code 1\n"
        + "Original token count: 0\nOutput:\n"

    @Test("a saved search that matched nothing settles, as the live one does")
    func aSavedSearchThatMatchedNothingSettles() {
        let vm = saved("rg -n absent src", output: emptyExitOne, isError: true)
        #expect(vm?.state == .done)
        #expect(vm?.isError == false)
        #expect(vm?.output == "")
        #expect(vm?.searchResultText == "")
        let tool = vm.map { DescribeToolCall.describe($0) }
        #expect(tool?.kind == .search)
        #expect(tool?.status == .succeeded)
        #expect(tool?.metric == .noMatch)
    }

    @Test("a saved search that broke, and a listing that exited 1, stay failed")
    func aSavedSearchThatBrokeStaysFailed() {
        let broken = saved("rg -n x missing", output: "rg: missing: No such file or directory (os error 2)",
                           isError: true)
        #expect(broken?.state == .error)
        #expect(broken?.isError == true)
        // Exit 1 means "nothing selected" for a search only.
        let listing = saved("ls missing", output: emptyExitOne, isError: true)
        #expect(listing?.toolName == "glob")
        #expect(listing?.state == .error)
        #expect(listing?.isError == true)
    }
}
