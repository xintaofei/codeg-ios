import Foundation

/// Typed errors surfaced by `CodegClient`.
enum APIError: LocalizedError, Sendable {
    case invalidURL
    case unauthorized
    case turnInProgress
    case server(status: Int, code: String?, message: String)
    case transport(String)
    case decoding(String)
    /// A live agent connection vanished server-side (a WS attach returned
    /// `detached { reason: "connection_gone" }`). Like an HTTP stale connection,
    /// the right recovery is a fresh `acp_connect` + retry.
    case streamGone

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server address is not a valid URL."
        case .unauthorized:
            return "Authentication failed. Check the server token."
        case .turnInProgress:
            return "A turn is already running on this session."
        case .server(let status, let code, let message):
            if let code { return "\(message) (\(code), HTTP \(status))" }
            return "\(message) (HTTP \(status))"
        case .transport(let detail):
            return "Network error: \(detail)"
        case .decoding(let detail):
            return "Could not read the server response: \(detail)"
        case .streamGone:
            return "The agent connection is no longer available."
        }
    }

    /// The folder isn't a git repository — the server's git endpoints guard with
    /// `ensure_git_repo`, returning HTTP 422 `not_a_git_repository`. Lets the
    /// Changes/Commits views show a calm "not a repo" state instead of an error.
    var isNotAGitRepository: Bool {
        if case .server(_, let code, _) = self { return code == "not_a_git_repository" }
        return false
    }

    /// A mid-turn message was refused because the turn had already ended. The
    /// server maps this to a 400 under the generic `invalid_input` code it shares
    /// with the other feedback rejections (empty text, feature unavailable), so
    /// the message is the only discriminator — the same marker the web client
    /// matches. Expected and recoverable: the caller sends the draft as an
    /// ordinary prompt instead of surfacing an error.
    var isNoActiveTurn: Bool {
        if case .server(_, _, let message) = self {
            return message.lowercased().contains("no active turn")
        }
        return false
    }

    /// A remote git operation (push/pull/fetch) failed to authenticate — the
    /// server returns `authentication_failed`, or git's own message leaks through.
    /// Mirrors the web `isAuthError` so the credential-retry flow can decide to
    /// prompt for a token/credentials and retry.
    var isAuthFailure: Bool {
        switch self {
        case .unauthorized:
            // Server-token auth, not a git remote — never trigger the git prompt.
            return false
        case .server(_, let code, let message):
            if code == "authentication_failed" { return true }
            let lower = message.lowercased()
            return lower.contains("authentication failed")
                || lower.contains("could not read username")
                || lower.contains("could not read password")
                || lower.contains("logon failed")
        default:
            return false
        }
    }

    /// True for conditions where a fresh `acp_connect` + retry is the right fix.
    var isStaleConnection: Bool {
        switch self {
        case .streamGone:
            return true
        case .server(let status, let code, _):
            return status == 404 || code == "connection_not_found" || code == "unknown_connection"
        default:
            return false
        }
    }

    /// Transient failures worth a brief, silent retry before alarming the user: a
    /// dropped/timed-out transport, or a 5xx (the server hiccuped). Auth (401),
    /// other 4xx (turn-in-progress, not-a-repo, …), and decoding errors are
    /// deterministic — retrying only delays the inevitable, so they fail fast.
    var isTransient: Bool {
        switch self {
        case .transport:
            return true
        case .server(let status, _, _):
            return status >= 500
        default:
            return false
        }
    }
}

/// Run a network read up to `attempts` times, retrying ONLY transient failures
/// (see ``APIError/isTransient``) with a short exponential backoff. Most of the
/// "network error" banners users hit are a single momentary blip — Wi-Fi waking,
/// one dropped packet, a brief AP roam — that a sub-second retry rides out
/// invisibly. Non-transient errors and task cancellation propagate immediately,
/// so a real auth/decoding failure (or a disappearing view) isn't delayed.
func withNetworkRetry<T>(
    attempts: Int = 2,
    _ operation: () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        attempt += 1
        try Task.checkCancellation()
        do {
            return try await operation()
        } catch let error as APIError where error.isTransient && attempt < attempts {
            // 0.4s, 0.8s, … — long enough to clear a transient drop, short enough
            // to stay below notice. Cancellation aborts the wait promptly.
            try await Task.sleep(for: .milliseconds(400 * (1 << (attempt - 1))))
        }
    }
}
