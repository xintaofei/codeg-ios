import Foundation

// Server calls behind the composer's inline `/` menu and `@` panel: the skills
// an agent's sessions load from disk, and the workspace file search.

// MARK: - Models

/// One workspace file search hit (Rust `WorkspaceFileEntry`): `path` is
/// relative to the searched root and always forward-slashed.
struct WorkspaceFileEntry: Decodable, Hashable, Sendable, Identifiable {
    enum Kind: String, Hashable, Sendable { case file, dir }

    let name: String
    let path: String
    let kind: Kind

    var id: String { path }

    private enum CodingKeys: String, CodingKey { case name, path, kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        let rawName = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        name = rawName.isEmpty ? (path.split(separator: "/").last.map(String.init) ?? path) : rawName
        kind = (try c.decodeIfPresent(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:)) ?? .file
    }

    init(name: String, path: String, kind: Kind) {
        self.name = name; self.path = path; self.kind = kind
    }
}

/// Identifies one search to the backend (Rust `SearchRequest`): the generation
/// must strictly increase per consumer — a stale one is answered with `[]` —
/// and naming the current one is how a search is cancelled.
struct WorkspaceSearchRequest: Encodable, Hashable, Sendable {
    let consumerId: String
    let generation: UInt64
}

// MARK: - Bodies

struct WorkspaceFileSearchBody: Encodable, Sendable {
    let path: String
    let query: String
    let limit: Int
    let request: WorkspaceSearchRequest
}

struct CancelWorkspaceFileSearchBody: Encodable, Sendable {
    let request: WorkspaceSearchRequest
}

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

    /// Rank the workspace's files against `query` server-side and return at
    /// most `limit` (clamped 1…200 by the server). The first search of a cold
    /// root builds its index — the backend bounds that at five minutes — so
    /// this rides a session that waits as long (web: `timeoutMs: 330_000`).
    func searchWorkspaceFiles(path: String, query: String, limit: Int,
                              request: WorkspaceSearchRequest) async throws -> [WorkspaceFileEntry] {
        try await postJSON("search_workspace_files",
                           WorkspaceFileSearchBody(path: path, query: query, limit: limit, request: request),
                           session: Self.fileSearchSession)
    }

    /// Stop the search `request` names (and any older one of its consumer).
    func cancelWorkspaceFileSearch(request: WorkspaceSearchRequest) async throws {
        _ = try await send("cancel_workspace_file_search", body: CancelWorkspaceFileSearchBody(request: request))
    }

    /// A cold index can sit silent for minutes before answering, so the
    /// inactivity timeout has to outlast the backend's own five-minute bound.
    static let fileSearchSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 330
        cfg.timeoutIntervalForResource = 360
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()
}
