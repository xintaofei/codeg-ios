import Foundation
import Testing
@testable import Codeg

/// Saving an MCP server means "these apps and no others" on the server, so
/// whatever the editor doesn't offer as a toggle has to go back out as it came.
struct McpAppSelectionTests {
    private func decodeServer(_ json: String) throws -> LocalMcpServer {
        try JSONDecoder().decode(LocalMcpServer.self, from: Data(json.utf8))
    }

    @Test func everyAppStringSurvivesDecoding() throws {
        let server = try decodeServer(#"""
        {"id":"fs","spec":{"type":"stdio","command":"npx"},
         "apps":["claude_code","grok","kimi_code","pi","open_claw","future_agent"]}
        """#)
        #expect(server.apps.map(\.rawValue) == ["claude_code", "grok", "kimi_code", "pi", "open_claw", "future_agent"])
    }

    @Test func appsEncodeAsTheirWireStrings() throws {
        let body = McpUpsertBody(serverId: "fs", spec: .object([:]), apps: [.kimiCode, McpAppType(rawValue: "future_agent")])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        #expect(json?["apps"] as? [String] == ["kimi_code", "future_agent"])
    }

    @Test func togglesSaveInDisplayOrder() {
        let apps = McpAppSelection.apps(selected: [.cursor, .claudeCode, .grok], existing: [])
        #expect(apps == [.claudeCode, .grok, .cursor])
    }

    @Test func appsNotOfferedAsTogglesAreKept() {
        let unknown = McpAppType(rawValue: "future_agent")
        let existing: [McpAppType] = [.claudeCode, .pi, .openClaw, unknown]
        // The user turned Claude Code off and Grok on; the rest isn't theirs to touch here.
        let apps = McpAppSelection.apps(selected: Set(existing).subtracting([.claudeCode]).union([.grok]),
                                        existing: existing)
        #expect(apps == [.grok, .pi, .openClaw, unknown])
    }

    @Test func aServerOnlyOnAHiddenAppStillSaves() {
        #expect(McpAppSelection.apps(selected: [], existing: [.pi]) == [.pi])
    }

    @Test func turningAnOfferedAppOffRemovesIt() {
        let apps = McpAppSelection.apps(selected: [], existing: [.kimiCode, .cursor])
        #expect(apps.isEmpty)
    }

    @Test func repeatedExistingAppsAreSentOnce() {
        let apps = McpAppSelection.apps(selected: [.codex], existing: [.codex, .pi, .pi])
        #expect(apps == [.codex, .pi])
    }

    @Test func offeredAppsMatchTheServersAssignableSet() {
        // The server's ALL_MCP_APPS (mcp.rs) less the two scan-only apps.
        let server: Set<String> = [
            "claude_code", "codex", "gemini", "open_claw", "open_code", "cline", "hermes",
            "code_buddy", "kimi_code", "grok", "cursor", "deepseek", "qoder", "antigravity",
            "kiro", "pi", "zcode", "trae", "command_code", "minimax_code",
        ]
        #expect(Set(McpAppType.assignable.map(\.rawValue)) == server.subtracting(["open_claw", "pi"]))
        #expect(McpAppType.assignable.allSatisfy { $0.displayName != $0.rawValue })
    }

    @Test func theScanDecodesWithItsWarnings() throws {
        let scan = try CodegJSON.decoder.decode(LocalMcpScan.self, from: Data(#"""
        {"servers":[{"id":"fs","spec":{"type":"stdio"},"apps":["cursor"]}],
         "warnings":[{"app":"kiro","message":"invalid JSON at line 3"},{"app":7}]}
        """#.utf8))
        #expect(scan.servers.map(\.id) == ["fs"])
        #expect(scan.warnings == [LocalMcpSourceWarning(app: .kiro, message: "invalid JSON at line 3")])
    }

    @Test func aServerOlderThanTheScanObjectStillLists() throws {
        // Before codeg 0.30.2 the route answered the bare server list.
        let scan = try CodegJSON.decoder.decode(LocalMcpScan.self, from: Data(#"""
        [{"id":"fs","spec":{},"apps":["claude_code"]}]
        """#.utf8))
        #expect(scan.servers.map(\.id) == ["fs"])
        #expect(scan.warnings.isEmpty)
    }

    @Test func aSpecsOwnKeysSurviveTheSnakeCaseDecoder() throws {
        // The spec is written back verbatim on save: env names and the like
        // must not come back camel-cased.
        let scan = try CodegJSON.decoder.decode(LocalMcpScan.self, from: Data(#"""
        {"servers":[{"id":"gh","spec":{"type":"stdio","command":"npx",
          "env":{"GITHUB_TOKEN":"x","api_key":"y"}},"apps":["codex"]}],"warnings":[]}
        """#.utf8))
        guard case .object(let spec)? = scan.servers.first?.spec,
              case .object(let env)? = spec["env"] else {
            Issue.record("spec did not decode as an object")
            return
        }
        #expect(Set(env.keys) == ["GITHUB_TOKEN", "api_key"])
    }
}
