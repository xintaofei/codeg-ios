import SwiftUI
import Observation

/// Per-agent skill files. Loads the server's usable agents, then the selected
/// agent's skills (global scope — folder-scoped skills are deferred to a later
/// pass, since they need a workspace picker). CRUD mirrors the web's skills page.
@MainActor
@Observable
final class SkillsSettingsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var agents: [AgentType] = []
    private(set) var selectedAgent: AgentType?
    private(set) var result: AgentSkillsListResult?
    /// The agent `result` actually belongs to — mutations target THIS, not
    /// `selectedAgent`, so a fast agent switch can't retarget a read/save/delete.
    private(set) var resultAgent: AgentType?
    private(set) var skillsLoading = false
    var refreshError: String?

    /// Monotonic token so a slow `listAgentSkills` for a previously-selected
    /// agent can't overwrite the current selection's results.
    private var loadToken = 0

    private let client: CodegClient?

    init(client: CodegClient?) { self.client = client }

    func load() async {
        guard let client else { phase = .failed("No server selected."); return }
        if agents.isEmpty { phase = .loading }
        do {
            let list = try await client.listAgents()
            CustomAgentRegistry.shared.ingest(list)
            // `supportsSkills` gates the matrix the way the web does: every
            // built-in has a codeg-known skill store, but a user-registered ACP
            // agent only does once its definition declares one (shared
            // `.agents/skills` or a dedicated dir). Listing one that hasn't would
            // offer an editor with nowhere to write.
            agents = list.filter { $0.available && $0.enabled && $0.supportsSkills }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.agentType)
            phase = .loaded
            if selectedAgent == nil || !(agents.contains(selectedAgent!)) {
                selectedAgent = agents.first
            }
            if let agent = selectedAgent { await loadSkills(agent) }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func select(_ agent: AgentType) async {
        guard agent != selectedAgent else { return }
        selectedAgent = agent
        result = nil
        resultAgent = nil
        await loadSkills(agent)
    }

    private func loadSkills(_ agent: AgentType) async {
        guard let client else { return }
        loadToken += 1
        let token = loadToken
        skillsLoading = true
        defer { if token == loadToken { skillsLoading = false } }
        do {
            let loaded = try await client.listAgentSkills(agentType: agent)
            guard token == loadToken else { return } // superseded by a newer selection
            result = loaded
            resultAgent = agent
            refreshError = nil
        } catch {
            guard token == loadToken else { return }
            refreshError = error.localizedDescription
        }
    }

    func reloadCurrent() async {
        if let agent = selectedAgent { await loadSkills(agent) }
    }

    /// Skills grouped by scope (global first), each sorted by name.
    var grouped: [(scope: AgentSkillScope, items: [AgentSkillItem])] {
        let skills = result?.skills ?? []
        let order: [AgentSkillScope] = [.global, .project]
        return order.compactMap { scope in
            let items = skills.filter { $0.scope == scope }.sorted { $0.name < $1.name }
            return items.isEmpty ? nil : (scope, items)
        }
    }

    // read/save/delete take the agent EXPLICITLY (captured by the view at
    // interaction time) rather than reading `selectedAgent` at execution time, so
    // a fast agent switch can't retarget the mutation. The post-mutation refresh
    // is applied only if that agent is still selected.

    func content(of skill: AgentSkillItem, agent: AgentType) async throws -> String {
        guard let client else { return "" }
        return try await client.readAgentSkill(agentType: agent, scope: skill.scope, skillId: skill.id).content
    }

    func save(skillId: String, scope: AgentSkillScope, content: String, layout: AgentSkillLayout?, agent: AgentType) async throws {
        guard let client else { return }
        _ = try await client.saveAgentSkill(agentType: agent, scope: scope, skillId: skillId, content: content, layout: layout)
        if agent == selectedAgent { await loadSkills(agent) }
    }

    func delete(_ skill: AgentSkillItem, agent: AgentType) async {
        guard let client else { return }
        do {
            try await client.deleteAgentSkill(agentType: agent, scope: skill.scope, skillId: skill.id)
            if agent == selectedAgent { await loadSkills(agent) }
        } catch {
            // Don't surface A's failure on B's view if the user switched mid-delete.
            if agent == selectedAgent { refreshError = error.localizedDescription }
        }
    }
}
