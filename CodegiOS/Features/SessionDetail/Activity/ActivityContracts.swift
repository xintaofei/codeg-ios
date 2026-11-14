import Foundation

// The small value types the activity modules hand each other — the shapes the
// web declares in `command.ts`, `exit-meaning.ts`, `edit.ts`, `mcp.ts` and
// `approval.ts` (codeg 0.44). Kept in one file so each module's port can be
// written against them independently; the functions that produce them live in
// their own module files.

/// A command's exit status (web `CommandExit`).
struct CommandExit: Equatable, Hashable, Sendable {
    /// Process exit code, when one was reported.
    var code: Int?
    /// Terminating signal (`SIGKILL`), when the process was killed by one.
    var signal: String?
}

/// A command whose first line opens a heredoc (web `HeredocCommand`).
struct HeredocCommand: Equatable, Hashable, Sendable {
    /// The command's first line, ending in the `<<'PY'` opener.
    var head: String
    /// Program the script is fed to (`python`, `node`, `bash`), basename only.
    var interpreter: String?
    /// Lines between the opener and the closing delimiter.
    var bodyLines: Int
}

/// What a command's non-zero exit says (web `ExitMeaning` = `ExitAnswer |
/// ExitCause`). The first four are ANSWERS — the command succeeded, its exit
/// is what it found; the last three name a failure.
enum ExitMeaning: String, Equatable, Hashable, Sendable {
    case noMatch, `false`, differs, notFound
    case commandNotFound, notExecutable, timedOut

    var isAnswer: Bool {
        switch self {
        case .noMatch, .false, .differs, .notFound: return true
        case .commandNotFound, .notExecutable, .timedOut: return false
        }
    }
}

/// How an edit touched a file (web `EditFileOp`).
enum EditFileOp: String, Equatable, Hashable, Sendable {
    case add, update, delete, move, write
}

/// One file an edit changed (web `EditFileChange`).
struct EditFileChange: Equatable, Hashable, Sendable {
    /// The file as it stands after the edit (a move's destination).
    var path: String
    /// A move's source path.
    var fromPath: String?
    var op: EditFileOp
    /// Nil when the payload does not say (a notebook cell edit, a bare path).
    var additions: Int?
    var deletions: Int?
    /// First and last line of the new file the edit changed — only when the
    /// payload carried real positions. Never estimated.
    var lineRange: ClosedRange<Int>?
}

/// A third-party MCP tool's identity (web `McpIdentity`).
struct McpIdentity: Equatable, Hashable, Sendable {
    var server: String
    var tool: String
}

/// How a call's permission request was answered (web `ToolApproval`).
struct ToolApproval: Equatable, Hashable, Sendable {
    enum Decision: String, Equatable, Hashable, Sendable {
        case allowOnce, allowAlways, rejected
    }
    var decision: Decision
    /// The chosen option's label in the agent's own words.
    var optionName: String?
    /// `user`, `chat_channel`, `cli_policy`; anything else reads as unknown.
    var origin: String?
    /// ISO timestamp.
    var decidedAt: String?
}
