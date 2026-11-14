import Foundation
import Testing
@testable import Codeg

/// `src/lib/activity/code-mode.ts` has no test file of its own; these pin the
/// behaviour its doc comments promise.
struct ActivityCodeModeTests {
    private let script = #"{"code":"// fetch the issue\nconst issue = await tools.linear.get_issue({id: 1})\nreturn issue"}"#

    @Test func codeModeScriptSourceReadsAnExecuteCallsCode() {
        #expect(ActivityCodeMode.codeModeScriptSource(script)?.hasPrefix("// fetch the issue") == true)
        #expect(ActivityCodeMode.isCodeModeScriptCall(normalizedToolName: "bash", input: script))
        #expect(!ActivityCodeMode.isCodeModeScriptCall(normalizedToolName: "read", input: script))
    }

    @Test func codeModeScriptSourceRejectsAnythingACommandCarries() {
        #expect(ActivityCodeMode.codeModeScriptSource(#"{"code":"ls","command":"ls"}"#) == nil)
        // Present at all counts, even as null.
        #expect(ActivityCodeMode.codeModeScriptSource(#"{"code":"ls","args":null}"#) == nil)
        #expect(ActivityCodeMode.codeModeScriptSource(#"{"code":"   "}"#) == nil)
        #expect(ActivityCodeMode.codeModeScriptSource(#"{"code":42}"#) == nil)
        #expect(ActivityCodeMode.codeModeScriptSource(#"{"command":"ls"}"#) == nil)
        #expect(ActivityCodeMode.codeModeScriptSource(nil) == nil)
        #expect(!ActivityCodeMode.isCodeModeScriptCall(normalizedToolName: "bash", input: #"{"command":"ls"}"#))
    }

    @Test func codeModeCallsReadsTheMetaRecordAndSkipsMalformedEntries() {
        let meta: [String: Any] = [
            ActivityCodeMode.callsMetaKey: [
                ["tool": " probe.echo ", "status": "completed", "input": ["text": "hi"]],
                ["tool": "codeg-mcp.ask_user_question", "status": "weird", "input": ["not", "an", "object"]],
                ["tool": "   "],
                "not an object",
                ["status": "error"],
            ],
        ]
        let calls = ActivityCodeMode.codeModeCalls(rawMeta: meta)
        #expect(calls == [
            CodeModeCall(tool: "probe.echo", status: .completed, input: ["text": .string("hi")]),
            CodeModeCall(tool: "codeg-mcp.ask_user_question", status: .running, input: nil),
        ])
        #expect(ActivityCodeMode.codeModeCalls(AnyJSON(any: meta)) == calls)
        #expect(ActivityCodeMode.codeModeCalls(nil).isEmpty)
        #expect(ActivityCodeMode.codeModeCalls(.array([])).isEmpty)
    }

    @Test func parseScriptCardTitlesAScriptByTheToolsItCalled() {
        let meta: [String: Any] = [
            ActivityCodeMode.callsMetaKey: [
                ["tool": "linear.get_issue", "status": "completed"],
                ["tool": "linear.get_issue", "status": "completed"],
                ["tool": "github.search_code", "status": "running"],
            ],
        ]
        let card = ActivityCodeMode.parseScriptCard(script, rawMeta: meta)
        #expect(card?.title == "linear.get_issue, github.search_code")
        #expect(card?.callCount == 3)
    }

    @Test func parseScriptCardFallsBackToTheFirstLineThatSaysSomething() {
        let card = ActivityCodeMode.parseScriptCard(script, meta: nil)
        #expect(card?.title == "const issue = await tools.linear.get_issue({id: 1})")
        #expect(card?.callCount == 0)
    }

    @Test func parseScriptCardPrefersCodexsSyntheticCard() {
        let codex = #"{"source":"await tools.exec_command({cmd})","title":"exec","call_count":2}"#
        #expect(ActivityCodeMode.parseScriptCard(codex, meta: nil)
            == ScriptCard(source: "await tools.exec_command({cmd})", title: "exec", callCount: 2))
        // A boolean count is not a count.
        #expect(ActivityCodeMode.parseCodexScriptCard(#"{"source":"x","call_count":true}"#)?.callCount == 0)
        #expect(ActivityCodeMode.parseCodexScriptCard(#"{"source":1}"#) == nil)
        #expect(ActivityCodeMode.parseScriptCard(#"{"command":"ls"}"#, meta: nil) == nil)
    }
}
