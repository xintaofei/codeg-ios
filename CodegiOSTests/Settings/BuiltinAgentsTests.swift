import Foundation
import Testing
@testable import Codeg

// The eight agents built in since codeg 0.24 (Android 5353e77) and the ACP
// adapter explainer (Android d05d95c, web `buildAcpAdapterCheck`).

@Suite struct NewBuiltinAgentsTests {
    private let wires = ["deepseek", "qoder", "antigravity", "kiro", "zcode", "trae", "command_code", "minimax_code"]

    @Test func theyAreBuiltinsThatRoundTrip() {
        for wire in wires {
            let agent = AgentType(rawValue: wire)
            #expect(agent?.isBuiltin == true, "\(wire)")
            #expect(agent?.rawValue == wire)
            #expect(agent?.iconAsset != nil, "\(wire) has a brand mark")
            #expect(agent?.isManagedOnDesktop == true, "\(wire) has no panel here")
            #expect(AgentType.builtins.contains(agent!))
        }
        #expect(AgentType.claudeCode.isManagedOnDesktop == false)
        // A custom agent registered under one of those names before it was
        // built in stays a custom identity of its own.
        #expect(AgentType(rawValue: "custom:zcode")?.isBuiltin == false)
    }

    @Test func theyCarryTheWebsNames() {
        #expect(AgentType.deepSeek.displayName == "DeepSeek Harness")
        #expect(AgentType.antigravity.displayName == "Google Antigravity")
        #expect(AgentType.kiro.displayName == "Kiro CLI")
        #expect(AgentType.trae.displayName == "TRAE CLI")
        #expect(AgentType.miniMaxCode.shortName == "MiniMax")
    }

    @Test func onlyTheMonoMarksTint() {
        #expect(AgentType.qoder.iconIsTemplate)
        #expect(AgentType.antigravity.iconIsTemplate)
        #expect(!AgentType.deepSeek.iconIsTemplate)
        #expect(!AgentType.trae.iconIsTemplate)
    }
}

@Suite struct AdapterInfoTests {
    private func preflight(_ adapter: [String: Any]?) throws -> PreflightResult {
        var json: [String: Any] = ["agent_type": "claude_code", "agent_name": "Claude Code", "passed": true, "checks": []]
        if let adapter { json["adapter"] = adapter }
        return try CodegJSON.decoder.decode(PreflightResult.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func adapter(installed: Bool, nativePath: Any = NSNull(), required: Bool = false) -> [String: Any] {
        ["adapter_package": "@agentclientprotocol/claude-agent-acp@0.81.1", "adapter_cmd": "claude-agent-acp",
         "adapter_installed": installed, "native_cmd": "claude", "native_label": "Claude Code CLI",
         "native_path": nativePath, "native_required": required, "shared_config_dir": "~/.claude",
         "docs_url": "https://example.com/acp"]
    }

    @Test func onlyAnAdapterAgentCarriesIt() throws {
        #expect(try preflight(nil).adapter == nil)
        let info = try #require(try preflight(adapter(installed: true)).adapter)
        #expect(info.adapterCmd == "claude-agent-acp")
        #expect(info.nativePath == nil)
        #expect(info.isSettled)
    }

    @Test func eachStateNamesWhatItIsAbout() throws {
        let ready = try #require(try preflight(adapter(installed: true, nativePath: "/usr/local/bin/claude")).adapter)
        #expect(ready.explanation.contains("/usr/local/bin/claude"))
        #expect(ready.explanation.contains("claude-agent-acp"))
        let missing = try #require(try preflight(adapter(installed: false)).adapter)
        #expect(!missing.isSettled)
        #expect(missing.explanation.contains("@agentclientprotocol/claude-agent-acp@0.81.1"))
        let missingWithNative = try #require(try preflight(adapter(installed: false, nativePath: "/opt/claude")).adapter)
        #expect(missingWithNative.explanation.contains("/opt/claude"))
        // A bridge that needs the official runtime: settled only with both.
        let bridge = try #require(try preflight(adapter(installed: true, required: true)).adapter)
        #expect(!bridge.isSettled)
        #expect(try preflight(adapter(installed: true, nativePath: "/opt/zcode", required: true)).adapter?.isSettled == true)
        // A blank path is none.
        #expect(try preflight(adapter(installed: true, nativePath: "  ")).adapter?.nativePath == nil)
    }
}
