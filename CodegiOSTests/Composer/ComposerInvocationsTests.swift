import Foundation
import Testing
@testable import Codeg

/// Web `composer/invocation-reference.test.ts` — the token rule, which agents
/// get disk skills under which trigger, and the `/` menu's skill dedup.
@Suite struct ComposerInvocationsTests {
    private func cmd(_ name: String, hint: String? = nil, skill: Bool = false, path: String? = nil) -> AvailableCommandInfo {
        AvailableCommandInfo(name: name, description: "\(name) command", inputHint: hint, skill: skill, skillPath: path)
    }

    private func skill(_ id: String, _ name: String) throws -> AgentSkillItem {
        try CodegJSON.decoder.decode(AgentSkillItem.self, from: Data("""
        {"id":"\(id)","name":"\(name)","scope":"project","layout":"markdown_file",
         "path":"/skills/\(id).md","description":"desc","read_only":false}
        """.utf8))
    }

    @Test func aCommandRunsAsSlashNameAndACodexSkillAsItsBareDollarName() {
        #expect(ComposerInvocations.commandInvocationToken("review") == "/review")
        #expect(ComposerInvocations.commandInvocationToken("$deploy") == "$deploy")
    }

    @Test func diskSkillsFollowTheAgent() throws {
        let antigravity = try #require(AgentType(rawValue: "antigravity"))
        let customAntigravity = try #require(AgentType(rawValue: "custom:antigravity-b"))
        let custom = try #require(AgentType(rawValue: "custom:my-agent"))
        #expect(ComposerInvocations.diskSkillTrigger(.codex) == .dollar)
        #expect(ComposerInvocations.diskSkillTrigger(antigravity) == .slash)
        #expect(ComposerInvocations.diskSkillTrigger(.openCode) == .slash)
        #expect(ComposerInvocations.diskSkillTrigger(customAntigravity) == .slash)
        #expect(ComposerInvocations.diskSkillTrigger(custom) == .slash)
        for agent in [AgentType.claudeCode, .kimiCode, .gemini] {
            #expect(ComposerInvocations.diskSkillTrigger(agent) == nil)
        }
        #expect(ComposerInvocations.diskSkillTrigger(nil) == nil)
    }

    @Test func aSlashSkillAnAdvertisedCommandShadowsIsLeftOut() throws {
        let skills = [try skill("plan", "Plan"), try skill("ship", "Ship")]
        #expect(ComposerInvocations.skillsForMenu(skills, commands: [cmd("plan"), cmd("usage")], trigger: .slash)
            .map(\.id) == ["ship"])
    }

    @Test func everyDollarSkillIsKept() throws {
        let skills = [try skill("plan", "Plan"), try skill("ship", "Ship")]
        #expect(ComposerInvocations.skillsForMenu(skills, commands: [cmd("plan"), cmd("$ship")], trigger: .dollar) == skills)
    }

    @Test func everySkillIsKeptWhileThereAreNoCommands() throws {
        let skills = [try skill("plan", "Plan")]
        #expect(ComposerInvocations.skillsForMenu(skills, commands: [], trigger: .slash) == skills)
    }

    @Test func theInputHintIsTrimmedAndBlankMeansNone() {
        #expect(ComposerInvocations.commandInputHint(cmd("review-branch", hint: " branch name ")) == "branch name")
        #expect(ComposerInvocations.commandInputHint(cmd("compact")) == nil)
        #expect(ComposerInvocations.commandInputHint(cmd("compact", hint: "  ")) == nil)
    }

    @Test func skillMarksCountOnlyInAListThatHasAPathlessSkill() {
        let userSkill = cmd("user-skill", skill: true, path: "/home/u/.claude/skills/user-skill/SKILL.md")
        let bundled = cmd("simplify", skill: true)
        let compact = cmd("compact")
        #expect(ComposerInvocations.skillMarkedCommands([userSkill, compact]).isEmpty,
                "the first pass marks only the skills with a SKILL.md")
        #expect(ComposerInvocations.skillMarkedCommands([userSkill, bundled, compact]) == ["user-skill", "simplify"])
    }

    @MainActor
    @Test func thePlusSheetInsertsTheSameToken() {
        let model = ComposeInsertModel(client: CodegClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: ""))
        #expect(model.draftAppendingCommand("$deploy", to: "") == "$deploy ")
        #expect(model.draftAppendingCommand("review", to: "please") == "please /review ")
    }

    /// 0.44 dropped `expertIdSet`: a command named like a known expert is
    /// listed like any other.
    @MainActor
    @Test func thePlusSheetNoLongerHidesExpertBackedCommands() async throws {
        let model = ComposeInsertModel(client: CodegClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: ""))
        let expert = try CodegJSON.decoder.decode(ExpertListItem.self, from: Data("""
        {"metadata":{"id":"code-review","category":"review","sort_order":0,
         "display_name":{"en":"Code Review"},"description":{}}}
        """.utf8))
        model.loadBuiltInExpertsAction = { return [expert] }
        model.loadExpertsAction = { return [expert] }
        model.load(.experts)
        try await waitUntil { model.phase(.experts) == .loaded }
        #expect(model.knownExpertIDs.contains("code-review"))

        let command = cmd("code-review")
        model.loadCommandsAction = { return [command] }
        model.load(.slashCommands)
        try await waitUntil { model.phase(.slashCommands) == .loaded }
        #expect(model.visibleCommands.map(\.name) == ["code-review"])
        #expect(!model.isEmpty(.slashCommands))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting")
    }
}
