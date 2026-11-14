import Foundation
import SwiftUI
import Testing
@testable import Codeg

/// The suggestion model end to end, without a server: what each trigger
/// lists, what a pick writes, and the mention tokens it registers.
@MainActor
@Suite struct ComposerSuggestionModelTests {
    /// Each model talks to a server of its own: the catalog is process-wide
    /// and keyed by server, so tests cannot see each other's lists.
    private func makeModel(agent: AgentType = .claudeCode, root: String? = nil) -> (ComposerSuggestionModel, String) {
        let url = URL(string: "http://127.0.0.1:9/\(UUID().uuidString)")!
        let model = ComposerSuggestionModel(client: CodegClient(baseURL: url, token: ""))
        model.context = { ComposerSuggestionModel.Context(agent: agent, workspaceRoot: root) }
        return (model, url.absoluteString)
    }

    private func cmd(_ name: String) -> AvailableCommandInfo {
        AvailableCommandInfo(name: name, description: "\(name) command", inputHint: nil)
    }

    private func skill(_ id: String) throws -> AgentSkillItem {
        try CodegJSON.decoder.decode(AgentSkillItem.self, from: Data("""
        {"id":"\(id)","name":"\(id.capitalized)","scope":"project","layout":"skill_directory",
         "path":"/s/\(id)","read_only":false}
        """.utf8))
    }

    private func agent(_ type: String, _ name: String, sortOrder: Int, enabled: Bool = true) throws -> AcpAgentInfo {
        try CodegJSON.decoder.decode(AcpAgentInfo.self, from: Data("""
        {"agent_type":"\(type)","registry_id":"\(type)","name":"\(name)","description":"\(name) agent",
         "available":true,"enabled":\(enabled),"sort_order":\(sortOrder)}
        """.utf8))
    }

    private func type(_ model: ComposerSuggestionModel, _ text: String, caret: Int? = nil) {
        model.update(text: text, caretUTF16: caret ?? text.utf16.count, focused: true)
    }

    // MARK: - `/`

    @Test func slashListsTheAgentsCommandsRankedAndPicksTheToken() throws {
        let (model, _) = makeModel()
        model.adoptLiveCommands([cmd("review"), cmd("compact"), cmd("$deploy")])
        type(model, "/re")
        let panel = try #require(model.panel)
        #expect(panel.rows == [.command(cmd("review"), skill: false)])
        let picked = try #require(model.pick(panel.rows[0], in: "/re"))
        #expect(picked.text == "/review ")
        #expect(picked.caret == 8)
        #expect(model.panel == nil, "a pick closes the menu")
    }

    @Test func aCodexSkillCommandIsInsertedAsItsBareDollarToken() throws {
        let (model, _) = makeModel(agent: .codex)
        model.adoptLiveCommands([cmd("$deploy")])
        type(model, "please /$d")
        let row = try #require(model.panel?.rows.first)
        let picked = try #require(model.pick(row, in: "please /$d"))
        #expect(picked.text == "please $deploy ")
    }

    @Test func noSpaceIsAddedWhenWhitespaceAlreadyFollows() throws {
        let (model, _) = makeModel()
        model.adoptLiveCommands([cmd("review")])
        type(model, "/re now", caret: 3)
        let row = try #require(model.panel?.rows.first)
        let picked = try #require(model.pick(row, in: "/re now"))
        #expect(picked.text == "/review now")
        #expect(picked.caret == 7)
    }

    @Test func anEmptyListClosesTheMenu() {
        let (model, _) = makeModel()
        type(model, "/")
        #expect(model.panel == nil)
    }

    @Test func aListOnItsWayShowsALoadingRowThatOwnsTheKeys() throws {
        let (model, _) = makeModel()
        model.fetchCommands = { _ in
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        type(model, "/")
        let panel = try #require(model.panel)
        #expect(panel.content == .commands(rows: [], loading: true, skillColumn: false))
        guard case .handled = model.handleKey(.return, shift: false, text: "/") else {
            Issue.record("the loading row must swallow Return")
            return
        }
    }

    @Test func aLiveListBeatsAFetchThatWasAlreadyOut() async throws {
        let (model, _) = makeModel()
        let stale = cmd("stale")
        model.fetchCommands = { _ in
            try? await Task.sleep(for: .milliseconds(50))
            return [stale]
        }
        type(model, "/")
        #expect(model.commandsLoading)
        model.adoptLiveCommands([cmd("fresh")])
        for _ in 0..<200 where model.commandsLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.commandsLoading)
        #expect(model.commands.map(\.name) == ["fresh"])
    }

    @Test func arrowsMoveTheHighlightAndReturnPicksIt() throws {
        let (model, _) = makeModel()
        model.adoptLiveCommands([cmd("review"), cmd("rebase"), cmd("reset")])
        type(model, "/re")
        // Prefix ties: shorter first, then input order.
        #expect(model.panel?.rows.map(\.id) == ["cmd:reset", "cmd:review", "cmd:rebase"])
        guard case .handled = model.handleKey(.downArrow, shift: false, text: "/re") else {
            Issue.record("down arrow")
            return
        }
        #expect(model.panel?.highlighted == 1)
        guard case .replace(let text, let caret) = model.handleKey(.return, shift: false, text: "/re") else {
            Issue.record("return should pick")
            return
        }
        #expect(text == "/review ")
        #expect(caret == 8)
    }

    @Test func keysMidCompositionAreTheInputMethods() {
        let (model, _) = makeModel()
        model.adoptLiveCommands([cmd("review"), cmd("rebase"), cmd("reset")])
        // "re" is still pinyin being composed, and already in the text.
        type(model, "/re")
        for key: KeyEquivalent in [.downArrow, .upArrow, .tab, .return, .escape] {
            guard case .ignored = model.handleKey(key, shift: false, composing: true, text: "/re") else {
                Issue.record("\(key.character) taken mid-composition")
                return
            }
        }
        #expect(model.panel?.highlighted == 0)
        #expect(model.panel != nil, "Escape mid-composition leaves the menu open")
    }

    @Test func escapeClosesUntilTheTextChanges() {
        let (model, _) = makeModel()
        model.adoptLiveCommands([cmd("review")])
        type(model, "/re")
        #expect(model.panel != nil)
        _ = model.handleKey(.escape, shift: false, text: "/re")
        #expect(model.panel == nil)
        type(model, "/re", caret: 2)
        #expect(model.panel == nil, "moving the caret does not reopen it")
        type(model, "/rev")
        #expect(model.panel != nil)
    }

    @Test func aLostFocusClosesIt() {
        let (model, _) = makeModel()
        model.adoptLiveCommands([cmd("review")])
        type(model, "/re")
        model.update(text: "/re", caretUTF16: 3, focused: false)
        #expect(model.panel == nil)
    }

    @Test func diskSkillsShareTheSlashMenuWithoutShadowedOnes() throws {
        let (model, _) = makeModel(agent: .openCode)
        model.adoptLiveCommands([cmd("plan"), cmd("usage")])
        let key = model.catalogKey(model.context())
        ComposerCatalog.shared.skills[key] = ComposerCatalog.SkillsEntry(skills: [try skill("plan"), try skill("ship")])
        type(model, "/")
        #expect(model.panel?.rows.map(\.id) == ["cmd:plan", "cmd:usage", "skill:project:ship"])
    }

    @Test func codexListsItsDiskSkillsUnderDollarOnly() throws {
        let (model, _) = makeModel(agent: .codex)
        model.adoptLiveCommands([cmd("review")])
        let key = model.catalogKey(model.context())
        ComposerCatalog.shared.skills[key] = ComposerCatalog.SkillsEntry(skills: [try skill("ship")])
        type(model, "$sh")
        let row = try #require(model.panel?.rows.first)
        #expect(model.panel?.rows.count == 1)
        let picked = try #require(model.pick(row, in: "$sh"))
        #expect(picked.text == "$ship ")
        type(model, "/")
        #expect(model.panel?.rows.map(\.id) == ["cmd:review"])
    }

    // MARK: - `@`

    @Test func atListsEnabledAgentsAndPicksAMentionToken() throws {
        let (model, server) = makeModel()
        ComposerCatalog.shared.agents[server] = [
            try agent("codex", "Codex", sortOrder: 2),
            try agent("claude_code", "Claude Code", sortOrder: 1),
            try agent("gemini", "Gemini", sortOrder: 0, enabled: false),
        ]
        type(model, "ask @")
        let all = try #require(model.panel)
        guard case .mention(let tab, let rows, _, _, _, _, _) = all.content else {
            Issue.record("not the mention panel")
            return
        }
        #expect(tab == .agent)
        #expect(rows.map(\.id) == ["agent:claude_code", "agent:codex"])

        type(model, "ask @codex")
        let row = try #require(model.panel?.rows.first)
        let picked = try #require(model.pick(row, in: "ask @codex"))
        #expect(picked.text == "ask @Codex ")
        #expect(picked.caret == 11)
        #expect(model.encode(picked.text) == "ask [@Codex](codeg://agent/codex) ")
    }

    @Test func theCaretInsideAPickedMentionDoesNotReopenThePanel() throws {
        let (model, server) = makeModel()
        ComposerCatalog.shared.agents[server] = [try agent("codex", "Codex", sortOrder: 0)]
        type(model, "@co")
        let row = try #require(model.panel?.rows.first)
        let picked = try #require(model.pick(row, in: "@co"))
        type(model, picked.text + "x")
        type(model, picked.text + "x", caret: 3)
        #expect(model.panel == nil)
    }

    @Test func tabSwitchesTheMentionTab() throws {
        let (model, server) = makeModel()
        ComposerCatalog.shared.agents[server] = [try agent("codex", "Codex", sortOrder: 0)]
        type(model, "@")
        guard case .handled = model.handleKey(.tab, shift: false, text: "@") else {
            Issue.record("tab")
            return
        }
        guard case .mention(let tab, let rows, _, _, _, _, _)? = model.panel?.content else {
            Issue.record("not the mention panel")
            return
        }
        #expect(tab == .file)
        #expect(rows.isEmpty)
        guard case .ignored = model.handleKey(.return, shift: false, text: "@") else {
            Issue.record("an empty tab declines Return")
            return
        }
    }

    // MARK: - Restore

    @Test func aRestoredMessageReadsAsTokensAndSendsAsItWas() {
        let (model, _) = makeModel(root: "/repo")
        let wire = "see [app.ts](file:///repo/src/app.ts) and [@Codex](codeg://agent/codex)"
        let shown = model.restore(wire)
        #expect(shown == "see @src/app.ts and @Codex")
        #expect(model.references.count == 2)
        #expect(model.encode(shown) == wire)
        model.update(text: "", caretUTF16: 0, focused: true)
        #expect(model.references.isEmpty, "a cleared draft takes its mentions with it")
    }
}
