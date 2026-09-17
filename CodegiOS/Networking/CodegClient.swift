import Foundation

/// HTTP client for a single codeg server. Value type — cheap to create per
/// request; holds the resolved base URL + bearer token. All endpoints are
/// `POST /api/<name>`.
struct CodegClient: Sendable {
    let baseURL: URL
    let token: String
    let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = CodegClient.defaultSession) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    static let defaultSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    /// Snappier session for the frequently-polled list reads (folders +
    /// conversations). These normally answer in well under a second, so a dead
    /// LAN host should surface in ~15s rather than the 30s default — that keeps a
    /// retry quick and the failure banner from feeling stuck. The 60s resource
    /// cap still allows a slow-but-progressing transfer on a large server.
    static let readSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    /// Longer-timeout session for slow server operations: `acp_describe_agent_options`
    /// spawns a probe agent (up to ~60s to come up), and `clone_repository` runs a
    /// full `git clone` that can take a while. The 30s default would abort either.
    static let probeSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 150
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    /// Very-long-timeout session for agent install/upgrade/uninstall: the server's
    /// `acp_download_agent_binary` / `acp_prepare_npx_agent` / `acp_install_uv_tool`
    /// handlers block until the install finishes (a cold npx/uv install can take
    /// minutes — the web sets a 10-min ceiling on uv). `timeoutIntervalForRequest`
    /// is the inactivity timeout; `timeoutIntervalForResource` is the overall cap.
    static let installSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 900
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    // MARK: - Endpoints

    /// Validate connectivity + auth for a server profile. Uses the snappier read
    /// session (15s) so a dead LAN host surfaces as offline in ~15s rather than
    /// the 30s default — this endpoint normally answers in well under a second,
    /// and it backs the per-server status dots and the editor's Test Connection.
    func health() async throws -> HealthResponse {
        try await postJSON("health", EmptyBody(), session: Self.readSession)
    }

    /// All projects/folders known to the server.
    func listFolders() async throws -> [FolderDetail] {
        try await postJSON("list_all_folder_details", EmptyBody(), session: Self.readSession)
    }

    /// Folders shown in the workspace lists: open + `regular` only (the server
    /// excludes closed and `chat` scratch folders). Worktree children ARE included
    /// (they carry a `parentId`); the frontend hides those whose root is also open
    /// — see ``FolderVisibility``. Use ``listFolders()`` (the full set) for by-id
    /// lookups so a conversation in a worktree/chat folder still resolves.
    func listOpenFolders() async throws -> [FolderDetail] {
        try await postJSON("list_open_folder_details", EmptyBody(), session: Self.readSession)
    }

    /// Conversations, optionally filtered by folder / status / search text.
    func listConversations(
        folderIds: [Int]? = nil,
        status: String? = nil,
        search: String? = nil,
        sortBy: String? = nil
    ) async throws -> [ConversationSummary] {
        try await postJSON("list_all_conversations", ListConversationsBody(
            folderIds: folderIds,
            agentType: nil,
            search: search,
            sortBy: sortBy,
            status: status,
            includeChildren: nil
        ), session: Self.readSession)
    }

    /// Full session detail incl. message history.
    func conversationDetail(id: Int) async throws -> ConversationDetail {
        try await postJSON("get_folder_conversation", ConversationIdBody(conversationId: id))
    }

    /// Create a conversation row up front (before the first prompt) and return its
    /// id. The server broadcasts a `conversation_upsert` on creation, so every
    /// connected client (desktop / web) sees the new session immediately — unlike
    /// the implicit creation that happens when prompting with a nil `conversationId`,
    /// which announces the link only on the prompting client's own stream. Mirrors
    /// the web client's new-tab flow. Response is a bare JSON integer.
    func createConversation(folderId: Int, agentType: AgentType, title: String?) async throws -> Int {
        try await postJSON("create_conversation", CreateConversationBody(
            folderId: folderId,
            agentType: agentType,
            title: title
        ))
    }

    /// Pin or unpin a conversation. Server-side this sets/clears `pinned_at`
    /// (without touching `updated_at`); the response is `null`.
    func setPinned(conversationId: Int, pinned: Bool) async throws {
        _ = try await send("update_conversation_pinned",
                           body: UpdateConversationPinnedBody(conversationId: conversationId, pinned: pinned))
    }

    /// Rename a conversation (server `update_conversation_title`). Response is `null`.
    func renameConversation(conversationId: Int, title: String) async throws {
        _ = try await send("update_conversation_title",
                           body: UpdateConversationTitleBody(conversationId: conversationId, title: title))
    }

    /// Set a conversation's lifecycle status (server `update_conversation_status`).
    /// `status` is the raw wire value. Response is `null`.
    func updateStatus(conversationId: Int, status: ConversationStatus) async throws {
        _ = try await send("update_conversation_status",
                           body: UpdateConversationStatusBody(conversationId: conversationId, status: status.rawValue))
    }

    /// Permanently delete a conversation (server `delete_conversation`). Response is `null`.
    func deleteConversation(conversationId: Int) async throws {
        _ = try await send("delete_conversation",
                           body: ConversationIdBody(conversationId: conversationId))
    }

    // MARK: - Folder management (Folders tab "+" menu)

    /// Add a folder to the workspace by its absolute server-side path (upsert +
    /// mark open), returning its full detail. Used by "Open Folder" and after a
    /// clone to register the freshly cloned directory.
    func openFolder(path: String) async throws -> FolderDetail {
        try await postJSON("open_folder", PathBody(path: path))
    }

    /// The server's home directory — the directory browser's default start path.
    /// Returns a bare JSON string (decoded like `acp_connect`'s connection id).
    func homeDirectory() async throws -> String {
        try await postJSON("get_home_directory", EmptyBody())
    }

    /// Subdirectories of `path` for the server-side directory browser (the server
    /// returns directories only).
    func listDirectoryEntries(path: String) async throws -> [DirectoryEntry] {
        try await postJSON("list_directory_entries", PathBody(path: path))
    }

    /// Clone a git repo into `targetDir` (the full destination path) on the
    /// server. Pass `credentials` for a private repo. Runs a real `git clone`, so
    /// it uses the longer-timeout `probeSession`. Returns when the clone finishes;
    /// callers then `openFolder(path: targetDir)` to add it to the workspace.
    func cloneRepository(url: String, targetDir: String, credentials: GitCredentials?) async throws {
        _ = try await send(
            "clone_repository",
            body: CloneRepositoryBody(url: url, targetDir: targetDir, credentials: credentials),
            session: Self.probeSession
        )
    }

    /// Agents registered/installed on the server.
    func listAgents() async throws -> [AcpAgentInfo] {
        try await postJSON("acp_list_agents", EmptyBody())
    }

    /// Spawn (or resume, when `sessionId` is set) an agent process. Returns the
    /// connection id (a bare JSON string). `preferredModeId`/`preferredConfigValues`
    /// (the user's last-used selections) are applied by the server before it
    /// reports session state — see `SelectorPrefsStore`.
    func connect(
        agentType: AgentType,
        workingDir: String?,
        sessionId: String?,
        preferredModeId: String? = nil,
        preferredConfigValues: [String: String]? = nil
    ) async throws -> String {
        let data = try await send("acp_connect", body: ConnectBody(
            agentType: agentType,
            workingDir: workingDir,
            sessionId: sessionId,
            preferredModeId: preferredModeId,
            preferredConfigValues: preferredConfigValues
        ))
        return try Self.decodeConnectionID(data)
    }

    /// Send a prompt to a live connection. The reply streams over the WebSocket.
    func prompt(
        connectionId: String,
        blocks: [PromptInputBlock],
        folderId: Int?,
        conversationId: Int?,
        clientMessageId: String?
    ) async throws {
        _ = try await send("acp_prompt", body: PromptBody(
            connectionId: connectionId,
            blocks: blocks,
            folderId: folderId,
            conversationId: conversationId,
            clientMessageId: clientMessageId
        ))
    }

    /// Cancel the in-flight turn on a connection.
    func cancel(connectionId: String) async throws {
        _ = try await send("acp_cancel", body: ConnectionIdBody(connectionId: connectionId))
    }

    /// Resolve a `permission_request` (or ExitPlanMode) by picking an option. The
    /// agent continues — or stops, for a `reject*` option — and the rest of the
    /// turn streams over the WebSocket.
    func respondPermission(connectionId: String, requestId: String, optionId: String) async throws {
        _ = try await send("acp_respond_permission", body: RespondPermissionBody(
            connectionId: connectionId,
            requestId: requestId,
            optionId: optionId
        ))
    }

    /// Answer an `ask_user_question`. Pass `QuestionAnswer.dismissed` to decline.
    /// The agent resumes streaming once answered.
    func answerQuestion(connectionId: String, questionId: String, answer: QuestionAnswer) async throws {
        _ = try await send("acp_answer_question", body: AnswerQuestionBody(
            connectionId: connectionId,
            questionId: questionId,
            answer: answer
        ))
    }

    /// Resolve Grok's blocked `exit_plan_mode`. The backend broadcasts
    /// `plan_approval_resolved` so every client viewing the conversation clears
    /// its card, then unblocks the parked ext request.
    func answerPlanApproval(connectionId: String, approvalId: String,
                            decision: PlanApprovalDecision, feedback: String?) async throws {
        _ = try await send("acp_answer_plan_approval", body: AnswerPlanApprovalBody(
            connectionId: connectionId,
            approvalId: approvalId,
            answer: PlanApprovalAnswer(decision: decision, feedback: feedback)
        ))
    }

    /// Find a live connection already bound to a conversation, if any. The
    /// server requires `agentType` and uses `sessionId` (the conversation's
    /// `external_id`) to match a connection before the first prompt binds one.
    func findConnection(conversationId: Int, sessionId: String?, agentType: AgentType) async throws -> ConversationConnectionInfo? {
        let data = try await send("acp_find_connection_for_conversation",
                                  body: FindConnectionBody(
                                    conversationId: conversationId,
                                    sessionId: sessionId,
                                    agentType: agentType
                                  ))
        if Self.isJSONNull(data) { return nil }
        do { return try CodegJSON.decoder.decode(ConversationConnectionInfo.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    /// Enumerate the agent's configurable mode + config options. The server
    /// spawns a throwaway probe agent to answer, so this can be slow (uses the
    /// longer `probeSession` timeout). The returned `current*` values are the
    /// probe's session defaults, not the chat session's live state.
    func describeAgentOptions(agentType: AgentType, workingDir: String?) async throws -> AgentOptionsSnapshot {
        try await postJSON(
            "acp_describe_agent_options",
            DescribeAgentOptionsBody(agentType: agentType, workingDir: workingDir),
            session: Self.probeSession
        )
    }

    /// The AUTHORITATIVE live session state for a conversation (current mode +
    /// config), or nil when no live session is *bound to the conversation* yet.
    /// Used to load the options sheet for display. NOTE: a resumed connection is
    /// only bound to its conversation on the first prompt-link, so before that this
    /// returns nil even if a connection exists — reconcile-after-apply uses the
    /// by-connection variant below instead.
    func sessionSnapshot(conversationId: Int) async throws -> SessionSnapshot? {
        let data = try await send("acp_get_session_snapshot_by_conversation",
                                  body: ConversationIdBody(conversationId: conversationId))
        return try Self.decodeSnapshot(data)
    }

    /// The AUTHORITATIVE live session state for a specific connection id, or nil if
    /// the connection is gone. Used to reconcile after an apply against the exact
    /// connection the `set_*` command targeted — works even in the pre-first-prompt
    /// window where the connection isn't bound to a conversation yet.
    func connectionSnapshot(connectionId: String) async throws -> SessionSnapshot? {
        let data = try await send("acp_get_session_snapshot",
                                  body: ConnectionIdBody(connectionId: connectionId))
        return try Self.decodeSnapshot(data)
    }

    private static func decodeSnapshot(_ data: Data) throws -> SessionSnapshot? {
        if isJSONNull(data) { return nil }
        do { return try CodegJSON.decoder.decode(SessionSnapshot.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    /// Set the active mode on a live chat connection.
    func setMode(connectionId: String, modeId: String) async throws {
        _ = try await send("acp_set_mode", body: SetModeBody(connectionId: connectionId, modeId: modeId))
    }

    /// Set a select config option's value on a live chat connection.
    func setConfigOption(connectionId: String, configId: String, valueId: String) async throws {
        _ = try await send("acp_set_config_option",
                           body: SetConfigOptionBody(connectionId: connectionId, configId: configId, valueId: valueId))
    }

    // MARK: - Compose "+" menu sources

    /// Reusable message templates for the "+" menu's Quick Messages list.
    func quickMessages() async throws -> [QuickMessage] {
        try await postJSON("quick_messages_list", EmptyBody())
    }

    /// Experts/skills linked to an agent, for the "+" menu's Expert Skills list.
    ///
    /// There is no server-side "list for one agent" endpoint — web derives this
    /// client-side too (`useEnabledSkillIds`): fetch the global catalog plus the
    /// bulk per-(expert, agent) link-status snapshot, then keep only the entries
    /// linked to THIS agent. (An earlier version of this call posted to a
    /// `experts_list_for_agent` route that was never implemented server-side —
    /// every request 501'd in web/server mode.)
    func experts(agentType: AgentType) async throws -> [ExpertListItem] {
        async let catalog = builtInExperts()
        async let statuses = expertsAllInstallStatuses()
        let linkedIDs = Set(
            try await statuses
                .filter { $0.agentType == agentType && $0.state == .linkedToCodeg }
                .map(\.expertId)
        )
        return try await catalog.filter { linkedIDs.contains($0.id) }
    }

    /// The global built-in expert catalog (`experts_list`). Agent-linked experts
    /// are a subset of this; the web uses these ids as its "known expert" set when
    /// deciding whether to replace an existing expert mention in the draft.
    func builtInExperts() async throws -> [ExpertListItem] {
        try await postJSON("experts_list", EmptyBody())
    }

    /// Bulk (expert, agent) link-status snapshot — the same one call the web
    /// client fans out to office-tools/science and merges (`use-enabled-skill-ids.ts`);
    /// this app only manages built-in experts today, so no merge is needed here.
    func expertsAllInstallStatuses() async throws -> [ExpertInstallStatus] {
        try await postJSON("experts_list_all_install_statuses", EmptyBody())
    }

    // MARK: - Core request plumbing
    //
    // `postJSON` / `send(_:body:)` are `internal` (not `private`) so feature
    // extensions in other files (e.g. `CodegClient+Settings.swift`) can reuse the
    // same `POST /api/<name>` transport. The raw-body `send` stays private.

    func postJSON<Req: Encodable, Res: Decodable>(_ path: String, _ body: Req, session: URLSession? = nil) async throws -> Res {
        let data = try await send(path, body: body, session: session)
        do { return try CodegJSON.decoder.decode(Res.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    @discardableResult
    func send<Req: Encodable>(_ path: String, body: Req, session: URLSession? = nil) async throws -> Data {
        let encoded: Data
        do { encoded = try CodegJSON.encoder.encode(body) }
        catch { throw APIError.decoding(String(describing: error)) }
        return try await send(path, rawBody: encoded, session: session)
    }

    /// Internal (not private) so feature extensions can send a hand-built JSON
    /// body — used for settings objects that must preserve snake_case keys the
    /// shared encoder/decoder would otherwise mangle (e.g. delegation settings).
    func send(_ path: String, rawBody: Data, session: URLSession? = nil) async throws -> Data {
        let session = session ?? self.session
        let url = baseURL.appendingPathComponent("api").appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = rawBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("Malformed response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            let parsed = try? CodegJSON.decoder.decode(ServerError.self, from: data)
            if http.statusCode == 409 || parsed?.code == "turn_in_progress" {
                throw APIError.turnInProgress
            }
            throw APIError.server(
                status: http.statusCode,
                code: parsed?.code,
                message: parsed?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
        return data
    }

    // MARK: - Bare-value helpers

    /// `acp_connect` returns a bare JSON string connection id (server side:
    /// `Ok(Json(connection_id))`). Require exactly that: a non-empty JSON string.
    /// A `null`, object, array, empty body, or a stray proxy/HTML 200 must be
    /// rejected — otherwise we'd attach/prompt against a bogus id like "null" or
    /// "{}" and fail in confusing, harder-to-diagnose ways downstream.
    static func decodeConnectionID(_ data: Data) throws -> String {
        guard let raw = try? CodegJSON.decoder.decode(String.self, from: data) else {
            throw APIError.decoding("acp_connect did not return a connection id string")
        }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw APIError.decoding("acp_connect returned an empty connection id")
        }
        return id
    }

    static func isJSONNull(_ data: Data) -> Bool {
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || s == "null"
    }
}

// MARK: - Server pulse (folders + conversations)

/// Result of a combined folders + conversations load (the Chats list + Activity
/// "pulse"). A `nil` list means that endpoint failed after retries; the caller
/// keeps its prior value for it, so one endpoint blipping degrades gracefully
/// instead of turning the whole screen red.
struct ServerSnapshotLoad {
    /// The full folder set (`list_all_folder_details`) — for by-id lookups (a
    /// conversation's folder name/path, incl. worktree and chat folders).
    let folders: [FolderDetail]?
    /// The workspace-visible folder set (`list_open_folder_details`, open+regular)
    /// — the source for the displayed Folders list / Chats grouping after
    /// ``FolderVisibility`` hides worktree children.
    let openFolders: [FolderDetail]?
    let conversations: [ConversationSummary]?
    /// User-facing message for the first failure, or nil when all succeeded.
    let message: String?
    /// The load was cancelled (view disappeared / a newer fetch superseded it) —
    /// callers leave their state untouched, matching the old `catch CancellationError`.
    let cancelled: Bool

    /// At least one endpoint returned data — the screen has something fresh to show.
    var anySucceeded: Bool { folders != nil || openFolders != nil || conversations != nil }
}

extension CodegClient {
    /// Concurrently load folders + conversations, each with its own transient
    /// retry, and report whichever succeeded. Folding the dual fetch here fixes
    /// two amplifiers of the old "network error" banner: the previous
    /// `try await (folders, conversations)` threw on the *first* failure (so one
    /// endpoint failing masked the other's success), and a single momentary blip
    /// surfaced instantly with no retry. Now a lone failure keeps the other half,
    /// and a sub-second hiccup is ridden out invisibly.
    func loadServerSnapshot() async -> ServerSnapshotLoad {
        async let foldersResult = resultOfRetry { try await self.listFolders() }
        async let openFoldersResult = resultOfRetry { try await self.listOpenFolders() }
        async let conversationsResult = resultOfRetry { try await self.listConversations() }
        let folders = await foldersResult
        let openFolders = await openFoldersResult
        let conversations = await conversationsResult

        // All fail with a cancellation when the awaiting task is torn down — report
        // it so callers don't clobber on-screen state with an empty/error result.
        if Task.isCancelled {
            return ServerSnapshotLoad(folders: nil, openFolders: nil, conversations: nil, message: nil, cancelled: true)
        }

        let firstError = folders.failureError ?? openFolders.failureError ?? conversations.failureError
        let message = firstError.map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription }
        return ServerSnapshotLoad(
            folders: try? folders.get(),
            openFolders: try? openFolders.get(),
            conversations: try? conversations.get(),
            message: message,
            cancelled: false
        )
    }

    /// Run one read through `withNetworkRetry`, capturing the outcome as a `Result`
    /// so a single endpoint's failure can't abort its sibling (each `async let`
    /// resolves independently).
    private func resultOfRetry<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await withNetworkRetry(operation)) }
        catch { return .failure(error) }
    }
}

private extension Result {
    /// The wrapped error if this is a `.failure`, else nil — for "first failure" picking.
    var failureError: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
