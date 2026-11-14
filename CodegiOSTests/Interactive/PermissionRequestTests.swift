import Foundation
import Testing
@testable import Codeg

/// `src/lib/permission-request.test.ts` (codeg 0.44): the request-level
/// `_meta.permission` block, the sandbox network request, the heading that must
/// not restate the command, the command-leaf `verbatim` mark, and the flat
/// option form — plus the parsed side of `permission-dialog.test.tsx` and the
/// iOS port of `mergePermissionToolCallWithLiveInfo`.
struct PermissionRequestTests {
    private func parse(_ toolCall: [String: Any]) -> ParsedPermission {
        ParsedPermission.parse(AnyJSON(any: toolCall))
    }

    /// Through the app's shared `.convertFromSnakeCase` decoder, the way a
    /// `permission_request` event's `tool_call` actually reaches the parser.
    private func decode(_ json: String) throws -> AnyJSON {
        try CodegJSON.decoder.decode(AnyJSON.self, from: Data(json.utf8))
    }

    private func changes(_ meta: [String: Any]?) -> [PermissionOptionChange] {
        PermissionOption(optionId: "o", name: "Allow", kind: "allow_once",
                         meta: meta.map { AnyJSON(any: $0) }).changes
    }

    // MARK: parsePermissionOptionChanges — flat form

    @Test func readsTheFlatDescriptionAsOneScopeLessChange() {
        #expect(changes(["permission": [
            "version": 1,
            "description": "Run the tool and remember this choice for this session.",
        ]]) == [PermissionOptionChange(
            description: "Run the tool and remember this choice for this session.", scope: nil)])
        // `changes[]` still wins where an adapter sends it.
        #expect(changes(["permission": [
            "version": 1,
            "description": "ignored",
            "changes": [["description": "kept", "lifetime": ["scope": "session"]]],
        ]]) == [PermissionOptionChange(description: "kept", scope: .session)])
        // Same version gate as the structured form.
        #expect(changes(["permission": ["version": 2, "description": "nope"]]).isEmpty)
        #expect(changes(nil).isEmpty)
    }

    // MARK: request-level _meta.permission

    @Test func surfacesTheCodexReasonAndPrefersItsTitleOverTheGenericOne() {
        let parsed = parse([
            "toolCallId": "command-7",
            "kind": "execute",
            "status": "pending",
            "title": "Run command",
            "rawInput": ["command": "npm test", "cwd": "/workspace"],
            "_meta": ["permission": [
                "version": 1,
                "title": "Run command?",
                "description": "The test suite needs to run outside the current sandbox.",
            ]],
        ])
        #expect(parsed.reason == "The test suite needs to run outside the current sandbox.")
        #expect(parsed.description == "Run command?")
        #expect(parsed.command == "npm test")
        #expect(parsed.title == "Run command")
    }

    @Test func keepsClaudesActionTitleAheadOfThePermissionTitle() {
        let parsed = parse([
            "toolCallId": "t1",
            "title": "npm test",
            "_meta": [
                "claudeCode": ["title": "Run the test suite"],
                "permission": ["version": 1, "title": "Run command?", "description": "why"],
            ],
        ])
        #expect(parsed.description == "Run the test suite")
        #expect(parsed.reason == "why")
    }

    @Test func reportsNoReasonForAgentsThatSendNoneOrAnUnreadableVersion() {
        #expect(parse(["toolCallId": "t1"]).reason == nil)
        #expect(parse(["toolCallId": "t1", "_meta": ["permission": ["version": 1, "title": "Make edits?"]]]).reason == nil)
        #expect(parse(["toolCallId": "t1", "_meta": ["permission": ["version": 2, "description": "unreadable"]]]).reason == nil)
    }

    @Test func boundsTheReasonToTheCardBudget() {
        let parsed = parse(["toolCallId": "t1", "_meta": ["permission": [
            "version": 1, "description": String(repeating: "y", count: 5_000),
        ]]])
        #expect(parsed.reason?.count == 200)
    }

    @Test func readsDefaultToNoUnderTheSameVersionGate() {
        #expect(parse(["toolCallId": "t1", "_meta": ["permission": [
            "version": 1, "title": "Run command?", "defaultToNo": true,
        ]]]).defaultToNo)
    }

    @Test func treatsAnythingButARealDefaultToNoTrueAsAbsent() {
        let cases: [[String: Any]] = [
            ["toolCallId": "t1"],
            ["toolCallId": "t1", "_meta": ["permission": ["version": 1]]],
            ["toolCallId": "t1", "_meta": ["permission": ["version": 1, "defaultToNo": "true"]]],
            ["toolCallId": "t1", "_meta": ["permission": ["version": 1, "defaultToNo": 1]]],
            ["toolCallId": "t1", "_meta": ["permission": ["version": 2, "defaultToNo": true]]],
        ]
        for toolCall in cases {
            #expect(parse(toolCall).defaultToNo == false)
        }
    }

    @Test func readsTheRequestLevelBlockThroughTheSharedDecoder() throws {
        let toolCall = try decode("""
        {"tool_call_id":"t1","title":"rm -rf build","kind":"execute",
         "raw_input":{"command":"rm -rf build"},
         "_meta":{"permission":{"version":1,"title":"Run command?","description":"Deletes the build","defaultToNo":true}}}
        """)
        let parsed = ParsedPermission.parse(toolCall)
        #expect(parsed.defaultToNo)
        #expect(parsed.reason == "Deletes the build")
        #expect(parsed.description == "Run command?")
        #expect(parsed.command == "rm -rf build")
    }

    // MARK: a sandbox network request

    @Test func readsTheHostOnlyWhenTheRequestNamesSandboxNetworkAccess() {
        let named = parse([
            "toolCallId": "n1",
            "title": "example.com",
            "rawInput": ["host": " example.com "],
            "_meta": ["claudeCode": ["toolName": "SandboxNetworkAccess"]],
        ])
        #expect(named.networkHost == "example.com")
        // It IS the structured body: no raw JSON preview.
        #expect(named.hasStructuredBody)

        let others: [[String: Any]] = [
            // The bare request, before the live call lent it a name.
            ["toolCallId": "n1", "title": "example.com", "rawInput": ["host": "x.dev"]],
            // Another tool that takes a host.
            ["toolCallId": "n2", "rawInput": ["host": "x.dev"], "_meta": ["claudeCode": ["toolName": "mcp__net__ping"]]],
            // The right tool with no host to name.
            ["toolCallId": "n3", "rawInput": ["host": "  "], "_meta": ["claudeCode": ["toolName": "SandboxNetworkAccess"]]],
        ]
        for toolCall in others {
            #expect(parse(toolCall).networkHost == nil)
        }
    }

    @Test func keepsAHostOnlyRequestFromAnythingElseOnTheJSONPreview() {
        let parsed = parse(["toolCallId": "t1", "title": "ping", "rawInput": ["host": "example.com"]])
        #expect(parsed.networkHost == nil)
        #expect(!parsed.hasStructuredBody)
        #expect(parsed.jsonPreview.contains("example.com"))
    }

    // MARK: a heading must not restate the command

    /// The exact frame claude-agent-acp 0.79.0 (#1070) sends for a shell
    /// approval: `title` and `_meta.permission.title` are both the raw command,
    /// and the model's label is left in `rawInput.description`.
    private func shellApproval(_ input: [String: Any], _ command: String) -> ParsedPermission {
        parse([
            "toolCallId": "toolu_01",
            "kind": "execute",
            "status": "pending",
            "title": command,
            "rawInput": input,
            "content": [["type": "content", "content": ["type": "text", "text": input["description"] ?? ""]]],
            "_meta": ["permission": ["version": 1, "title": command, "description": "Reason: policy"]],
        ])
    }

    @Test func showsACommandBlockForShellThatOpensWithABraceOrABracket() {
        for command in ["[ -f package.json ] && pnpm test", "{ npm test; }", "[System.Environment]::OSVersion"] {
            let parsed = shellApproval(["command": command, "description": "Check the project"], command)
            #expect(parsed.command == command)
            #expect(parsed.description == "Check the project")
        }
    }

    @Test func showsACommandBlockForACommandThatWritesAPatch() {
        let command = "cat <<'EOF' > fix.patch\n--- a/x.ts\n+++ b/x.ts\n@@ -1 +1 @@\n-a\n+b\nEOF"
        let parsed = shellApproval(["command": command, "description": "Write the patch file"], command)
        #expect(parsed.command == command)
        #expect(parsed.description == "Write the patch file")
    }

    @Test func stillUnwrapsAGenuinelyStringifiedArgvEnvelope() {
        #expect(parse(["toolCallId": "t1", "rawInput": ["argv": #"["bash","-lc","ls -la"]"#]]).command == "bash -lc ls -la")
    }

    @Test func keepsAnUnreadableOuterPayloadOutOfTheCommandBlock() {
        #expect(parse(["toolCallId": "t1", "rawInput": "{not json"]).command == nil)
        #expect(parse(["toolCallId": "t1", "rawInput": ["input": "*** Begin Patch\n*** Update File: x.ts\n"]]).command == nil)
    }

    @Test func doesNotLetACommandKeyLaunderAGenericPayloadIntoACommand() {
        #expect(parse(["toolCallId": "t1", "rawInput": ["args": ["payload": #"{"query":"hello"}"#]]]).command == nil)
        // Directly under the key, but a well-formed envelope carrying no command.
        #expect(parse(["toolCallId": "t1", "rawInput": ["args": #"{"a":1}"#]]).command == nil)
        // The diff guard likewise stops at the first wrapper hop.
        #expect(parse(["toolCallId": "t1", "rawInput": ["command": ["input": "*** Begin Patch\n*** Update File: x\n"]]]).command == nil)
    }

    @Test func takesTheModelsLabelBackWhenTheMetaHeadingIsTheCommand() {
        let parsed = shellApproval(["command": "pnpm test", "description": "Run the test suite"], "pnpm test")
        #expect(parsed.description == "Run the test suite")
        #expect(parsed.command == "pnpm test")
        #expect(parsed.title == "pnpm test")
        #expect(parsed.reason == "Reason: policy")
    }

    @Test func holdsForAMultiLineCommand() {
        let command = "set -e\nfor f in *.ts; do\n  echo \"$f\"\ndone"
        let parsed = shellApproval(["command": command, "description": "List the TypeScript files"], command)
        #expect(parsed.description == "List the TypeScript files")
        #expect(parsed.command == command)
    }

    @Test func keepsTheCommandAsTheHeadingWhenTheModelSuppliedNoLabel() {
        #expect(shellApproval(["command": "ls -la"], "ls -la").description == "ls -la")
    }

    @Test func doesNotPromoteALabelThatMerelyRepeatsTheCommand() {
        #expect(shellApproval(["command": "ls -la", "description": "ls -la"], "ls -la").description == "ls -la")
    }

    @Test func boundsAnAgentAuthoredLabelBeforeItBecomesAHeading() {
        let parsed = shellApproval(["command": "ls", "description": String(repeating: "x", count: 5_000)], "ls")
        #expect(parsed.description?.count == 200)
    }

    @Test func leavesEveryHeadingThatSaysSomethingTheCommandBlockDoesNot() {
        // codex-acp ≥1.7.0: four fixed titles, none of them the command.
        #expect(parse([
            "toolCallId": "command-7",
            "title": "Run command",
            "rawInput": ["command": "npm test", "description": "ignored here"],
            "_meta": ["permission": ["version": 1, "title": "Run command?"]],
        ]).description == "Run command?")
        // claude ≤0.78.0, whose `_meta.permission.title` already WAS the label.
        #expect(parse([
            "toolCallId": "toolu_01",
            "title": "Run the test suite",
            "rawInput": ["command": "pnpm test", "description": "Run the test suite"],
            "_meta": ["permission": ["version": 1, "title": "Run the test suite"]],
        ]).description == "Run the test suite")
        // A non-command card is untouched.
        #expect(parse([
            "toolCallId": "toolu_02",
            "title": "Write src/a.ts",
            "rawInput": ["file_path": "src/a.ts", "content": "x"],
            "_meta": ["permission": ["version": 1, "title": "Write src/a.ts"]],
        ]).description == "Write src/a.ts")
    }

    // MARK: permission-dialog.test.tsx (parsed side)

    @Test func theCodexReasonReplacesTheBoilerplateAndItsTitleBecomesTheHeading() {
        let parsed = parse([
            "title": "Edit files",
            "kind": "edit",
            "_meta": ["permission": [
                "version": 1,
                "title": "Make edits?",
                "description": "The migration renames a column used by two callers.",
            ]],
        ])
        #expect(parsed.reason == "The migration renames a column used by two callers.")
        #expect(parsed.description == "Make edits?")
    }

    @Test func framesTheRecordedSandboxNetworkRequestByItsHost() {
        // claude-agent-acp 0.98.0's request, with the tool name the merge copies
        // over from the live call.
        let parsed = parse([
            "toolCallId": "344c0506-799d-474e-bc8a-3ad269fa228a",
            "title": "example.com",
            "rawInput": ["host": "example.com"],
            "_meta": [
                "permission": ["version": 1, "title": "example.com"],
                "claudeCode": ["toolName": "SandboxNetworkAccess"],
            ],
            "kind": "other",
        ])
        #expect(parsed.networkHost == "example.com")
        #expect(parsed.hasStructuredBody)
        #expect(parsed.reason == nil)
    }

    // MARK: mergePermissionToolCallWithLiveInfo

    private func live(
        id: String = "call-1", title: String = "Live title", kind: String = "execute",
        rawInput: String? = nil, meta: [String: Any]? = nil
    ) -> PermissionLiveInfo {
        PermissionLiveInfo(toolCallId: id, title: title, kind: kind, rawInput: rawInput,
                           meta: meta.map { AnyJSON(any: $0) })
    }

    @Test func lendsTheLiveCallsClaudeCodeToolNameToABareNetworkRequest() throws {
        let request = try decode("""
        {"tool_call_id":"call-1","title":"example.com","raw_input":{"host":"example.com"},
         "_meta":{"permission":{"version":1,"title":"example.com"}}}
        """)
        #expect(PermissionLiveMerge.toolCallId(request) == "call-1")
        let merged = PermissionLiveMerge.merge(
            request, with: live(meta: ["claudeCode": ["toolName": "SandboxNetworkAccess"]]))
        let parsed = ParsedPermission.parse(merged)
        #expect(parsed.networkHost == "example.com")
        // The request's own permission block survives the meta rewrite.
        #expect(parsed.description == "example.com")
        #expect(merged.object?["_meta"]?.object?["permission"] != nil)
    }

    @Test func neverOverwritesAToolNameTheRequestAlreadyCarries() {
        let request = AnyJSON(any: [
            "toolCallId": "call-1", "title": "x", "rawInput": ["host": "example.com"],
            "_meta": ["claudeCode": ["toolName": "mcp__net__ping"]],
        ] as [String: Any])
        let merged = PermissionLiveMerge.merge(
            request, with: live(meta: ["claudeCode": ["toolName": "SandboxNetworkAccess"]]))
        #expect(ParsedPermission.parse(merged).networkHost == nil)
    }

    @Test func fillsAMissingInputTitleAndKindFromTheLiveCall() {
        let request = AnyJSON(any: ["toolCallId": "call-1"] as [String: Any])
        let merged = PermissionLiveMerge.merge(
            request, with: live(title: "Run tests", kind: "execute", rawInput: #"{"command":"npm test"}"#))
        let parsed = ParsedPermission.parse(merged)
        #expect(parsed.command == "npm test")
        #expect(parsed.title == "Run tests")
        #expect(parsed.kind == "execute")
    }

    @Test func putsTheEditTextBackIntoAStrippedEditApproval() throws {
        // claude-agent-acp 0.82.0: the request's input is `{file_path}` alone.
        let request = try decode("""
        {"tool_call_id":"call-1","title":"Edit a.ts","kind":"edit","raw_input":{"file_path":"src/a.ts"}}
        """)
        let liveInput = #"{"file_path":"src/a.ts","old_string":"let a = 1\n","new_string":"let a = 2\n"}"#
        let parsed = ParsedPermission.parse(PermissionLiveMerge.merge(request, with: live(rawInput: liveInput)))
        #expect(!parsed.diffFiles.isEmpty)
    }

    @Test func neverLendsEditTextAboutAnotherFile() throws {
        let request = try decode("""
        {"tool_call_id":"call-1","title":"Edit a.ts","kind":"edit","raw_input":{"file_path":"src/a.ts"}}
        """)
        let liveInput = #"{"file_path":"src/b.ts","old_string":"x\n","new_string":"y\n"}"#
        let merged = PermissionLiveMerge.merge(request, with: live(rawInput: liveInput))
        #expect(merged == request)
        #expect(ParsedPermission.parse(merged).diffFiles.isEmpty)
    }

    @Test func leavesARequestWithItsOwnEditTextAlone() {
        let request = AnyJSON(any: [
            "toolCallId": "call-1", "title": "Edit", "kind": "edit",
            "rawInput": ["file_path": "a.ts", "old_string": "a", "new_string": "b"],
        ] as [String: Any])
        let liveInput = #"{"file_path":"a.ts","old_string":"zzz","new_string":"qqq"}"#
        #expect(PermissionLiveMerge.merge(request, with: live(rawInput: liveInput)) == request)
    }

    @Test func pendingPermissionParsesTheMergedToolCall() {
        let pending = PendingPermission(
            requestId: "req-net",
            toolCall: AnyJSON(any: ["toolCallId": "call-1", "title": "example.com",
                                    "rawInput": ["host": "example.com"]] as [String: Any]),
            options: [],
            liveInfo: live(meta: ["claudeCode": ["toolName": "SandboxNetworkAccess"]])
        )
        #expect(pending.parsed.networkHost == "example.com")
    }

    // MARK: a request that reaches the client before its call

    private static let sandboxMeta = AnyJSON(any: ["claudeCode": ["toolName": "SandboxNetworkAccess"]] as [String: Any])

    /// claude-agent-acp 0.98.0's bare network request: no tool name, no kind.
    private func bareNetworkRequest(liveInfo: PermissionLiveInfo? = nil) -> PendingPermission {
        PendingPermission(
            requestId: "req-net",
            toolCall: AnyJSON(any: [
                "toolCallId": "net-1", "title": "example.com", "rawInput": ["host": "example.com"],
                "_meta": ["permission": ["version": 1, "title": "example.com"]],
            ] as [String: Any]),
            options: [PermissionOption(optionId: "allow", name: "Allow", kind: "allow_once", meta: nil)],
            liveInfo: liveInfo)
    }

    /// web: "tells a sandbox network request whose call arrives after it".
    @Test @MainActor func fillsARequestInFromTheCallAnnouncedAfterIt() throws {
        let live = LiveTurn()
        // The turn has not seen the call yet.
        let pending = bareNetworkRequest(liveInfo: live.permissionLiveInfo(for: bareNetworkRequest().toolCall))
        #expect(pending.parsed.networkHost == nil)
        #expect(pending.parsed.kind == "tool", "a request with no kind reads as the generic one")

        live.upsertToolCall(id: "net-1", title: "SandboxNetworkAccess", kind: "other", status: "pending",
                            rawInput: #"{"host":"other.dev"}"#, rawOutput: nil, content: nil,
                            meta: Self.sandboxMeta)
        let refreshed = try #require(pending.refreshed(by: live, toolCallId: "net-1"))
        #expect(refreshed.parsed.networkHost == "example.com")
        // Only gaps were filled: the request still names its own title, input
        // and permission block; the kind it left out came from the call.
        #expect(refreshed.requestId == "req-net")
        #expect(refreshed.options.map(\.optionId) == ["allow"])
        #expect(refreshed.parsed.title == "example.com")
        #expect(refreshed.parsed.description == "example.com")
        #expect(refreshed.parsed.kind == "other")
        #expect(refreshed.toolCall.object?["rawInput"] == AnyJSON(any: ["host": "example.com"] as [String: Any]))
        #expect(refreshed.toolCall.object?["_meta"]?.object?["permission"] != nil)
        // A later update that lends nothing new leaves the showing card alone.
        live.updateToolCall(id: "net-1", title: nil, status: "in_progress", rawInput: nil, rawOutput: "x",
                            content: nil, append: true)
        #expect(refreshed.refreshed(by: live, toolCallId: "net-1") == nil)
    }

    @Test @MainActor func fillsARequestInFromAnUpdateThatNamesTheTool() throws {
        let live = LiveTurn()
        live.upsertToolCall(id: "net-1", title: "example.com", kind: "other", status: "pending",
                            rawInput: nil, rawOutput: nil, content: nil)
        let pending = bareNetworkRequest(liveInfo: live.permissionLiveInfo(for: bareNetworkRequest().toolCall))
        #expect(pending.parsed.networkHost == nil)
        // Nothing new yet.
        #expect(pending.refreshed(by: live, toolCallId: "net-1") == nil)

        live.updateToolCall(id: "net-1", title: nil, status: nil, rawInput: nil, rawOutput: nil,
                            content: nil, append: false, meta: Self.sandboxMeta)
        let refreshed = try #require(pending.refreshed(by: live, toolCallId: "net-1"))
        #expect(refreshed.parsed.networkHost == "example.com")
    }

    @Test @MainActor func ignoresACallTheRequestIsNotAbout() {
        let live = LiveTurn()
        live.upsertToolCall(id: "other-1", title: "SandboxNetworkAccess", kind: "other", status: "pending",
                            rawInput: nil, rawOutput: nil, content: nil, meta: Self.sandboxMeta)
        #expect(bareNetworkRequest().refreshed(by: live, toolCallId: "other-1") == nil)
        // Nor one it names but this turn never saw.
        #expect(bareNetworkRequest().refreshed(by: live, toolCallId: "net-1") == nil)
    }

    @Test @MainActor func putsTheEditTextBackOnceTheCallArrives() throws {
        let live = LiveTurn()
        let pending = PendingPermission(
            requestId: "req-edit",
            toolCall: try decode("""
            {"tool_call_id":"call-1","title":"Edit a.ts","kind":"edit","raw_input":{"file_path":"src/a.ts"}}
            """),
            options: [])
        #expect(pending.parsed.diffFiles.isEmpty)
        live.upsertToolCall(id: "call-1", title: "Edit", kind: "edit", status: "pending",
                            rawInput: #"{"file_path":"src/a.ts","old_string":"let a = 1\n","new_string":"let a = 2\n"}"#,
                            rawOutput: nil, content: nil)
        let refreshed = try #require(pending.refreshed(by: live, toolCallId: "call-1"))
        #expect(!refreshed.parsed.diffFiles.isEmpty)
        #expect(refreshed.parsed.title == "Edit a.ts")
    }
}
