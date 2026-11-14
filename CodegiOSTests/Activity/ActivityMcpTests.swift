import Foundation
import Testing
@testable import Codeg

/// `src/lib/activity/mcp.test.ts`, plus the iOS-only key-order and number
/// formatting the web gets from JavaScript itself.
struct ActivityMcpTests {
    private func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: parseMcpToolName

    @Test func parseMcpToolNameReadsEveryHostsSpelling() {
        #expect(ActivityMcp.parseMcpToolName("mcp__linear__get_issue") == McpIdentity(server: "linear", tool: "get_issue"))
        #expect(ActivityMcp.parseMcpToolName("mcp__chrome-devtools__take_snapshot") == McpIdentity(server: "chrome-devtools", tool: "take_snapshot"))
        #expect(ActivityMcp.parseMcpToolName("linear/get_issue") == McpIdentity(server: "linear", tool: "get_issue"))
        #expect(ActivityMcp.parseMcpToolName("github.search_code") == McpIdentity(server: "github", tool: "search_code"))
        #expect(ActivityMcp.parseMcpToolName("context7:query-docs") == McpIdentity(server: "context7", tool: "query-docs"))
    }

    @Test func parseMcpToolNameRejectsNamesThatOnlyLookNamespaced() {
        #expect(ActivityMcp.parseMcpToolName("functions.exec_command") == nil)
        #expect(ActivityMcp.parseMcpToolName("Read") == nil)
        #expect(ActivityMcp.parseMcpToolName("Read file 'a.ts'") == nil)
    }

    @Test func parseMcpToolNameKeepsJavaScriptRegexSemantics() {
        // `/i` on the prefix; `\w` is ASCII-only; `.` does not cross a newline.
        #expect(ActivityMcp.parseMcpToolName("MCP__db__run_query") == McpIdentity(server: "db", tool: "run_query"))
        #expect(ActivityMcp.parseMcpToolName("café.get") == nil)
        #expect(ActivityMcp.parseMcpToolName("mcp__a__b\nc") == nil)
        #expect(ActivityMcp.parseMcpToolName("  mcp__a__b  ") == McpIdentity(server: "a", tool: "b"))
    }

    // MARK: mcpArgumentPreview

    @Test func mcpArgumentPreviewNamesTheCallByItsFirstValue() {
        #expect(ActivityMcp.mcpArgumentPreview(#"{"id":"HVAC-212"}"#) == "HVAC-212")
        #expect(ActivityMcp.mcpArgumentPreview(#"{"limit":5}"#) == "5")
        #expect(ActivityMcp.mcpArgumentPreview(#"{"filter":{"a":1}}"#) == nil)
        #expect(ActivityMcp.mcpArgumentPreview(nil) == nil)
    }

    @Test func mcpArgumentPreviewWalksValuesInJavaScriptOrder() {
        #expect(ActivityMcp.mcpArgumentPreview(#"{"query":"foo","limit":5}"#) == "foo")
        #expect(ActivityMcp.mcpArgumentPreview(#"{"limit":5,"query":"foo"}"#) == "5")
        // Array-index keys come first, as `Object.values` yields them.
        #expect(ActivityMcp.mcpArgumentPreview(#"{"b":"x","1":"y"}"#) == "y")
        // Escaped keys still line up with the parsed object.
        #expect(ActivityMcp.mcpArgumentPreview(#"{"z\u0041":"first","a":"second"}"#) == "first")
        // Booleans are not numbers; blank strings are skipped.
        #expect(ActivityMcp.mcpArgumentPreview(#"{"flag":true,"s":"  ","n":2.5}"#) == "2.5")
        #expect(ActivityMcp.mcpArgumentPreview("plain words") == "plain words")
        #expect(ActivityMcp.mcpArgumentPreview(#"{"truncated":"#) == nil)
    }

    @Test func jsNumberStringMatchesJavaScript() {
        #expect(ActivityMcp.jsNumberString(5) == "5")
        #expect(ActivityMcp.jsNumberString(-0.0) == "0")
        #expect(ActivityMcp.jsNumberString(1.5) == "1.5")
        #expect(ActivityMcp.jsNumberString(0.000001) == "0.000001")
        #expect(ActivityMcp.jsNumberString(1e-7) == "1e-7")
        #expect(ActivityMcp.jsNumberString(1e20) == "100000000000000000000")
        #expect(ActivityMcp.jsNumberString(1e21) == "1e+21")
        #expect(ActivityMcp.jsNumberString(1.25e22) == "1.25e+22")
        #expect(ActivityMcp.jsNumberString(-42) == "-42")
    }

    // MARK: mcpResultPayload

    @Test func mcpResultPayloadReadsAPlainJsonResult() {
        #expect(ActivityMcp.mcpResultPayload(#"{"title":"Bug"}"#)
            == McpResultPayload(json: .object(["title": .string("Bug")]), text: nil, isError: false))
    }

    @Test func mcpResultPayloadParsesACallToolResultsJsonTextBlock() {
        let output = json(["content": [["type": "text", "text": #"{"title":"Inactive bindings"}"#]]])
        #expect(ActivityMcp.mcpResultLabel(ActivityMcp.mcpResultPayload(output)) == "Inactive bindings")
    }

    @Test func mcpResultPayloadPrefersStructuredContent() {
        let output = json([
            "content": [["type": "text", "text": "ignored"]],
            "structuredContent": ["name": "repo"],
        ])
        #expect(ActivityMcp.mcpResultPayload(output)?.json == .object(["name": .string("repo")]))
    }

    @Test func mcpResultPayloadPeelsCodexsEnvelopesAndSurfacesItsHostError() {
        let ok = json([
            "result": ["content": [["type": "text", "text": "plain words"]]],
            "error": NSNull(),
        ])
        #expect(ActivityMcp.mcpResultPayload(ok) == McpResultPayload(json: nil, text: "plain words", isError: false))
        let failed = json(["result": NSNull(), "error": "server crashed"])
        #expect(ActivityMcp.mcpResultPayload(failed) == McpResultPayload(json: nil, text: "server crashed", isError: true))
    }

    @Test func mcpResultPayloadKeepsNonJsonOutputAsText() {
        #expect(ActivityMcp.mcpResultPayload("all good") == McpResultPayload(json: nil, text: "all good", isError: false))
        #expect(ActivityMcp.mcpResultPayload("") == nil)
    }

    @Test func mcpResultPayloadReadsIsErrorOnlyAsABoolean() {
        let flagged = json(["content": [["type": "text", "text": "nope"]], "isError": true])
        #expect(ActivityMcp.mcpResultPayload(flagged)?.isError == true)
        let numeric = json(["content": [["type": "text", "text": "nope"]], "isError": 1])
        #expect(ActivityMcp.mcpResultPayload(numeric)?.isError == false)
    }

    @Test func mcpResultPayloadReadsABareContentArray() {
        let blocks = json([["type": "text", "text": "a"], ["type": "text", "text": "b"]])
        #expect(ActivityMcp.mcpResultPayload(blocks) == McpResultPayload(json: nil, text: "a\nb", isError: false))
        #expect(ActivityMcp.mcpResultPayload("[1,2]")?.json == .array([.number(1), .number(2)]))
    }

    // MARK: mcpResultLabel

    @Test func mcpResultLabelIsNilForResultsWithoutANamingField() {
        #expect(ActivityMcp.mcpResultLabel(ActivityMcp.mcpResultPayload(#"{"count":3}"#)) == nil)
        #expect(ActivityMcp.mcpResultLabel(nil) == nil)
    }
}
