import Foundation

/// What an ACP `error` event means for the turn it arrives in, keyed on its
/// stable `code`. Port of the web's `src/lib/acp-error-presentation.ts`
/// (codeg 0.44).
///
/// The backend raises one `error` event for very different things: a turn that
/// failed, an agent that died, a mode switch the agent refused, an image Grok
/// dropped, a compaction that failed while the turn carried on uncompacted.
/// Only some of them END the turn. Treating every one as fatal — which this
/// client used to — closes the stream on a turn that is still running, so
/// the rest of the reply never arrives until the session is reopened.
enum AcpErrorRoute: Equatable {
    /// The turn failed: nothing came back, or the agent would not run it.
    /// Closes the live turn with the failure line.
    case failsTurn(message: String)
    /// Worth telling the user, but the turn (and connection) go on. Shown as a
    /// transient notice; the turn still ends through `turn_complete`, or — if
    /// the agent really died — the `status_changed: error` the backend always
    /// sends right after a terminal error.
    case notice(message: String)
    /// Already shown by a card in the transcript (a failed compaction). The
    /// backend raises the event for stream-only readers, not for this screen.
    case silent

    /// The verdicts that mean the turn FAILED, as opposed to one that ended
    /// early WITH output (`turn_failed_refusal`, `turn_failed_max_tokens`, …),
    /// which ends normally through `turn_complete`. Mirrors the web's
    /// `FAILED_TURN_VERDICTS`.
    static let failedTurnVerdicts: Set<String> = [
        "turn_failed_auth_required",
        "turn_failed_empty",
        "turn_failed_empty_protocol",
        "turn_failed_empty_metadata",
        "turn_failed_unknown",
    ]

    /// Codes whose condition is already rendered in the transcript.
    static let transcriptCodes: Set<String> = ["compaction_failed"]

    static func route(code: String?, message: String) -> AcpErrorRoute {
        guard let code, !code.isEmpty else {
            // No code: a prompt the agent rejected, and the message is the
            // agent's own words — wrapped by the backend's `AcpError::protocol`
            // Display, whose prefix says nothing to the user.
            return .failsTurn(message: rejectedPromptText(message))
        }
        if failedTurnVerdicts.contains(code) { return .failsTurn(message: message) }
        if transcriptCodes.contains(code) { return .silent }
        return .notice(message: message)
    }

    /// Mirrors the web's `rejectedPromptText`.
    static func rejectedPromptText(_ message: String) -> String {
        guard let range = message.range(of: #"^ACP protocol error:\s*"#, options: .regularExpression) else {
            return message
        }
        let stripped = String(message[range.upperBound...])
        return stripped.isEmpty ? message : stripped
    }
}
