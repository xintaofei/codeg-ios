import Foundation

/// Small facts about tools that `describeToolCall` consults, each a port of a
/// helper from a web lib outside `src/lib/activity` (codeg 0.44): background
/// launches (`background-task.ts`), the codeg-mcp workbench companions
/// (`codeg-mcp-tool.ts`), the collab tool (`collab-tool.ts`), the delegate
/// tool's host spellings (`delegation-card.ts`) and a command's announced
/// shell session (`shell-session-tool.ts`).
///
/// opencode code-mode delegation (`isCodeModeDelegationCall`, an `execute`
/// call whose JavaScript `code` calls `delegate_to_agent`) has its own port,
/// ``CodeModeDelegation``: it is a whole JS scanner, not a small fact.
enum ActivityToolFacts {
    // MARK: background launches

    /// Claude Code's Bash acknowledgement for a command that keeps running in
    /// the background — four wordings, one per reason it left the foreground
    /// (a `run_in_background` launch, Ctrl+B, a steer arriving mid-command
    /// since Claude Code 2.1.286, a command outliving its timeout).
    private static let launchPatterns: [NSRegularExpression] = [
        #"Command (?:running in background with ID:|was manually backgrounded by user with ID:|was moved to the background \(ID:|did not complete within its \d+s timeout and was moved to the background \(ID:)\s*([A-Za-z0-9_-]+)"#,
        // Grok's `run_terminal_command(background: true)` acknowledgement.
        #"Background task\s+([A-Za-z0-9_-]+)\s+started"#,
        // OpenCode 2's shell acknowledgement (`backgroundResult`, 2.2.0).
        #"Command moved to the background \(shell ID:\s*([A-Za-z0-9_-]+)\)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// The task id of a background launch result, if the output is one.
    static func backgroundLaunchTaskId(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let ns = text as NSString
        for re in launchPatterns {
            if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: m.range(at: 1))
            }
        }
        return nil
    }

    // MARK: tool names (all take the NORMALIZED name)

    /// The codeg-mcp workbench companions, in canonical form.
    static let codegMcpWorkbenchTools: Set<String> = [
        "get_session_info", "task_progress", "task_complete",
        "create_automation", "create_work_task", "resume_delegation",
    ]

    static func isCodegMcpWorkbenchTool(_ name: String) -> Bool {
        codegMcpWorkbenchTools.contains(name.lowercased().trimmingCharacters(in: .whitespaces))
    }

    static let collabAgentToolName = "collab_agent"

    /// The multi-agent `delegate_to_agent` companion: the bare canonical name
    /// plus any host's server-prefixed form (`mcp__<server>__delegate_to_agent`,
    /// `<server>/delegate_to_agent`, `<server>.delegate_to_agent`).
    static func isDelegateToAgentToolName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "delegate_to_agent"
            || lower.range(of: #"[^a-z0-9]delegate_to_agent$"#, options: .regularExpression) != nil
    }

    // MARK: shell sessions

    /// `SESSION_ID=<n>` on a line of its own — the announcement a script
    /// echoes for the background session later `wait` calls address.
    private static let announcedSessionId = try! NSRegularExpression(
        pattern: #"^[ \t]*SESSION_ID[ \t]*=[ \t]*(\d+)[ \t\r]*$"#, options: [.anchorsMatchLines])

    static func announcedSessionId(_ output: String?) -> String? {
        guard let output else { return nil }
        let ns = output as NSString
        guard let m = announcedSessionId.firstMatch(in: output, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }
}
