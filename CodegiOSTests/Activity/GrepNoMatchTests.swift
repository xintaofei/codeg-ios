import Foundation
import Testing
@testable import Codeg

/// A codex search that found nothing, reported as failed — the live shape of
/// the web's `isGrepNoMatchResult` (`ai-elements-adapter.test.ts`, codeg 0.44)
/// and Android's `GrepNoMatchTest` (a04bfa0), with the command guard's vectors
/// from the web's `grep-no-match.test.ts`.
@MainActor
struct GrepNoMatchTests {
    /// The command from codeg #877, as codex-acp sent it.
    static let issue877 = "rg --files scripts src/grapal/phonics tests | rg 'sequence_(nested|rerank_candidate)'"
    static let marked = AnyJSON.parse(jsonString: #"{"codeg.codexSearchAction":true}"#)

    // MARK: - pipelineStages

    @Test("splits a pipeline and keeps a `|` inside quotes")
    func splitsAPipeline() {
        #expect(GrepNoMatch.pipelineStages(Self.issue877) == [
            ["rg", "--files", "scripts", "src/grapal/phonics", "tests"],
            ["rg", "sequence_(nested|rerank_candidate)"],
        ])
    }

    @Test("resolves quotes and backslashes the POSIX way")
    func resolvesQuotesAndBackslashes() {
        #expect(GrepNoMatch.pipelineStages(#"grep -e "a \"b\" \d" 'c'"d" e\ f"#)
                == [["grep", "-e", #"a "b" \d"#, "cd", "e f"]])
        #expect(GrepNoMatch.pipelineStages("rg ''") == [["rg", ""]])
    }

    @Test("drops redirections the last stage cannot fail to set up")
    func dropsHarmlessRedirections() {
        #expect(GrepNoMatch.pipelineStages(
            "rg --files 2>err.log < in | rg -n x 2>/dev/null >/dev/null 2>&1 >&2 &>>/dev/null")
                == [["rg", "--files"], ["rg", "-n", "x"]])
    }

    static let refusedScripts: [String] = [
        // A last-stage redirection the shell can fail to set up.
        "cat /dev/null | grep needle 2>/dev/null </dev/null/codeg-877",
        "rg x 2>/dev/null > out.txt",
        "rg x 2>/dev/null >> /tmp/log",
        "rg x <> f",
        "rg x <&3",
        "rg x 2>/dev/null >&3",
        "< in grep x",
        // Anything but one plain pipeline.
        "rg --files && rg x",
        "rg x || true",
        "rg a; rg b",
        "rg a\nrg b",
        "rg a & rg b",
        "(rg a) | rg b",
        "rg $(cat pattern)",
        "rg \"$(cat pattern)\"",
        "rg `cat pattern`",
        "false $'\\' | grep -q x'\\'",
        "rg x <(ls)",
        "grep x <<EOF",
        "rg x # why",
        "rg --files |& rg x",
        "rg --files | | rg x",
        "rg --files |",
        "rg x >",
        "rg x > > out",
        "rg 'x",
        "rg \"x",
        "rg x\\",
        "   ",
    ]

    @Test("refuses anything but one plain pipeline", arguments: refusedScripts)
    func refusesAnythingButOnePlainPipeline(_ script: String) {
        #expect(GrepNoMatch.pipelineStages(script) == nil)
    }

    // MARK: - endsInGrepSearch

    static let searchCommands: [String] = [
        issue877,
        "rg -n '__absent__' README.md",
        "cat README.md | grep -n '__absent__'",
        "ls | egrep x",
        "fgrep -r x src",
        "/opt/homebrew/bin/rg x",
        "LC_ALL=C GREP_COLOR=1 grep x f",
        "'rg' x",
        "bash -lc 'rg --files | rg x'",
        "/bin/zsh -lc \"\(issue877)\"",
        "/bin/zsh -lc \"bash -c 'rg x'\"",
    ]

    @Test("accepts a command whose status is the search's", arguments: searchCommands)
    func acceptsASearch(_ command: String) {
        #expect(GrepNoMatch.endsInGrepSearch(.script(command)))
    }

    @Test("accepts an argv, with or without a shell wrapper")
    func acceptsAnArgv() {
        #expect(GrepNoMatch.endsInGrepSearch(.argv(["rg", "-n", "x"])))
        #expect(GrepNoMatch.endsInGrepSearch(.argv(["bash", "-lc", Self.issue877])))
    }

    static let otherCommands: [String] = [
        "rg x | wc -l",
        "find . -name x",
        "fd x",
        "diff a b",
        "test -f x",
        "rg --files | xargs grep x",
        "! cat f | grep -q x",
        "bash -c '! cat f | grep -q x'",
        "git diff --exit-code",
        "git grep --no-index --open-files-in-pager=false x -- f",
        "A=1",
        "${IFS:+false$IFS}/grep needle",
        "bash -c '${IFS:+false$IFS}/grep needle'",
        "${IFS:+false$IFS}/bin/bash -lc 'rg x'",
        "$PREFIX/rg x",
        "~/bin/rg x",
        "/opt/*/bin/rg x",
        "grep -q needle f && test -d out",
        "bash -c 'rg x' zero one",
        "bash -e -c 'rg x'",
        "powershell.exe -Command 'rg x'",
    ]

    @Test("refuses a command whose status may not be the search's", arguments: otherCommands)
    func refusesOtherCommands(_ command: String) {
        #expect(!GrepNoMatch.endsInGrepSearch(.script(command)))
    }

    @Test("reads `command`, `cmd`, a bare JSON string, an argv and non-JSON text")
    func readsTheCommandFromTheInput() {
        #expect(GrepNoMatch.commandFromToolInput(#"{"command":"rg x","cwd":"/ws"}"#) == .script("rg x"))
        #expect(GrepNoMatch.commandFromToolInput(#"{"cmd":"rg x"}"#) == .script("rg x"))
        #expect(GrepNoMatch.commandFromToolInput(#""rg x""#) == .script("rg x"))
        #expect(GrepNoMatch.commandFromToolInput(#"{"command":["bash","-lc","rg x"]}"#) == .argv(["bash", "-lc", "rg x"]))
        #expect(GrepNoMatch.commandFromToolInput("rg x | head") == .script("rg x | head"))
        // A search action's own arguments name no command.
        #expect(GrepNoMatch.commandFromToolInput(#"{"pattern":"x","path":"src"}"#) == nil)
        #expect(GrepNoMatch.commandFromToolInput("42") == nil)
        #expect(GrepNoMatch.commandFromToolInput(nil) == nil)
    }

    // MARK: - The live codex search rule

    @Test("codex's search failing with nothing printed found nothing")
    func codexsSearchWithNothingPrintedFoundNothing() {
        #expect(GrepNoMatch.isCodexSearchNoMatch(toolName: "Search for 'x' in src", input: nil, output: nil, meta: Self.marked))
        #expect(GrepNoMatch.isCodexSearchNoMatch(toolName: "grep", input: #"{"pattern":"x"}"#, output: " \n", meta: Self.marked))
        #expect(GrepNoMatch.isCodexSearchNoMatch(toolName: "grep", input: #"{"command":"rg x"}"#, output: "", meta: Self.marked))
    }

    @Test("a diagnostic, a missing mark or another tool keeps the failure")
    func aDiagnosticOrAMissingMarkKeepsTheFailure() {
        // rg printed why: a real failure.
        #expect(!GrepNoMatch.isCodexSearchNoMatch(toolName: "grep", input: nil, output: "rg: regex parse error", meta: Self.marked))
        // Another adapter's interrupted grep looks exactly the same, unmarked.
        #expect(!GrepNoMatch.isCodexSearchNoMatch(toolName: "grep", input: nil, output: nil, meta: nil))
        #expect(!GrepNoMatch.isCodexSearchNoMatch(
            toolName: "grep", input: nil, output: nil,
            meta: AnyJSON.parse(jsonString: #"{"codeg.codexSearchAction":"true"}"#)))
        // A listing's exit 1 is a real failure; a session poll or a script cell is no search.
        #expect(!GrepNoMatch.isCodexSearchNoMatch(toolName: "List files", input: nil, output: nil, meta: Self.marked))
        #expect(!GrepNoMatch.isCodexSearchNoMatch(toolName: "wait", input: nil, output: nil, meta: Self.marked))
        #expect(!GrepNoMatch.isCodexSearchNoMatch(toolName: "write_stdin", input: nil, output: nil, meta: Self.marked))
        #expect(!GrepNoMatch.isCodexSearchNoMatch(toolName: "codex_script", input: nil, output: nil, meta: Self.marked))
    }

    @Test("a command the status may not come from keeps the failure")
    func aCommandTheStatusMayNotComeFromKeepsTheFailure() {
        for command in ["! rg x", "rg x > out.txt", "rg $(cat pattern)", "grep x <<EOF", "rg x | wc -l"] {
            let input = String(decoding: try! JSONSerialization.data(withJSONObject: ["command": command]), as: UTF8.self)
            #expect(!GrepNoMatch.isCodexSearchNoMatch(toolName: "grep", input: input, output: nil, meta: Self.marked),
                    "\(command)")
        }
    }

    // MARK: - Through the adapters

    private static func searchTurn(id: String, name: String = "Search for 'definitely absent'",
                                   output: String?, status: ToolUseStatus, meta: AnyJSON?,
                                   pairById: Bool = true) -> MessageTurn {
        let toolID = pairById ? "search-\(id)" : nil
        return MessageTurn(id: "codex-search-\(id)", role: .assistant, blocks: [
            .toolUse(id: toolID, name: name, inputPreview: #"{"pattern":"definitely absent"}"#,
                     status: status, meta: meta),
            .toolResult(id: toolID, outputPreview: output, isError: true, agentStats: nil),
        ], timestamp: Date())
    }

    private static func onlyCall(_ parts: [RenderPart]) -> ToolCallVM? {
        guard parts.count == 1, case .tool(let vm) = parts[0] else { return nil }
        return vm
    }

    @Test("a live failed codex search with no output settles as a success with no matches")
    func aLiveFailedSearchSettles() {
        let cases: [(label: String, pairById: Bool, output: String?)] = [
            ("id", true, nil), ("position", false, nil), ("blank", true, " \n"),
        ]
        for (label, pairById, output) in cases {
            let turn = Self.searchTurn(id: "settles-\(label)", output: output,
                                       status: .failed, meta: Self.marked, pairById: pairById)
            guard let vm = Self.onlyCall(MessageRender.adaptTurn(turn)) else {
                Issue.record("expected one tool call (\(label))"); continue
            }
            #expect(vm.state == .done, "\(label)")
            #expect(!vm.isError, "\(label)")
            // An empty body is what the search card draws as "No matches".
            #expect(vm.output == (output ?? ""), "\(label)")
            let tool = DescribeToolCall.describe(vm)
            #expect(tool.kind == .search, "\(label)")
            #expect(tool.status == .succeeded, "\(label)")
            #expect(tool.metric == .noMatch, "\(label)")
        }
    }

    @Test("a diagnostic, a glob, a persisted row and an unmarked grep stay failed")
    func otherFailuresStayFailed() {
        let cases: [(String, String, String?, ToolUseStatus, AnyJSON?)] = [
            ("diagnostic", "Search for 'definitely absent'", "rg: regex parse error", .failed, Self.marked),
            ("glob", "List files", nil, .failed, Self.marked),
            ("persisted", "Search for 'definitely absent'", nil, .unknown, Self.marked),
            ("unmarked", "Grep", nil, .failed, nil),
        ]
        for (label, name, output, status, meta) in cases {
            let turn = Self.searchTurn(id: "fails-\(label)", name: name, output: output, status: status, meta: meta)
            let vm = Self.onlyCall(MessageRender.adaptTurn(turn))
            #expect(vm?.state == .error, "\(label)")
            #expect(vm?.isError == true, "\(label)")
        }
    }

    @Test("the live stream settles it in place, and its folded copy keeps it settled")
    func theLiveStreamSettlesIt() {
        let live = LiveTurn()
        live.upsertToolCall(id: "live-search-1", title: "Search for 'definitely absent' in src", kind: "search",
                            status: "pending", rawInput: nil, rawOutput: nil, content: nil, meta: Self.marked)
        live.updateToolCall(id: "live-search-1", title: nil, status: "failed", rawInput: nil, rawOutput: nil,
                            content: nil, append: false, meta: nil)
        guard let vm = Self.onlyCall(MessageRender.adaptLive(live)) else {
            Issue.record("expected one live tool call"); return
        }
        #expect(vm.state == .done)
        #expect(!vm.isError)
        #expect(DescribeToolCall.describe(vm).status == .succeeded)

        // Folded into the transcript until the reconcile, it reads the same.
        guard let turn = live.snapshotAsMessageTurns().first,
              let folded = Self.onlyCall(MessageRender.adaptTurn(turn)) else {
            Issue.record("expected the folded copy's tool call"); return
        }
        #expect(folded.state == .done)
        #expect(!folded.isError)
    }

    @Test("a live search that printed a diagnostic, or is unmarked, stays failed")
    func aLiveDiagnosticStaysFailed() {
        let live = LiveTurn()
        live.upsertToolCall(id: "live-search-2", title: "Search for 'x'", kind: "search", status: "pending",
                            rawInput: nil, rawOutput: nil, content: nil, meta: Self.marked)
        live.updateToolCall(id: "live-search-2", title: nil, status: "failed", rawInput: nil,
                            rawOutput: "rg: regex parse error", content: nil, append: false, meta: nil)
        live.upsertToolCall(id: "live-search-3", title: "Search for 'y'", kind: "search", status: "failed",
                            rawInput: nil, rawOutput: nil, content: nil, meta: nil)
        let calls = MessageRender.adaptLive(live).compactMap { part -> ToolCallVM? in
            if case .tool(let vm) = part { return vm }
            return nil
        }
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.state == .error && $0.isError })
    }
}
