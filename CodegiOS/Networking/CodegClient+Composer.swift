import Foundation

// Server calls behind the composer's inline `/` menu: the skills an agent's
// sessions load from disk.

// MARK: - Endpoints

extension CodegClient {
    /// The skills an agent's sessions can load from `workspacePath`, for the
    /// composer menus (`acp_list_agent_runtime_skills`). For OpenCode that is
    /// more than the Skills settings page manages (`.claude` folders and the
    /// folders above the workspace); for every other agent the two agree.
    func listAgentRuntimeSkills(agentType: AgentType, workspacePath: String?) async throws -> AgentSkillsListResult {
        try await postJSON("acp_list_agent_runtime_skills",
                           AgentSkillsListBody(agentType: agentType, workspacePath: workspacePath))
    }
}
