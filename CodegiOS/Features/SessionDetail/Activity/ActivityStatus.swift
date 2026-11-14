import Foundation

/// Step statuses — port of the web's `src/lib/activity/status.ts` (codeg 0.44).
enum ActivityStatus {
    /// Claude Code's result for a call the user declined in the permission
    /// prompt, and the generic "rejected/denied by user" wording others use.
    private static let rejected = try! NSRegularExpression(
        pattern: #"^The user doesn't want to proceed with this tool use|\b(?:rejected|denied|declined) by (?:the )?user\b"#,
        options: [.caseInsensitive])
    /// Claude Code's result for a call the user stopped mid-flight.
    private static let interrupted = try! NSRegularExpression(
        pattern: #"^\[Request interrupted by user"#, options: [.caseInsensitive])

    private static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
        re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// The status of one tool call. Liveness comes only from the call's own
    /// lifecycle state (`ToolCallVM.state`, which already applies the
    /// transcript's liveness rules), so a call still treated as in flight is
    /// never painted finished here — the rule every other surface follows.
    static func of(_ call: ToolCallVM, awaiting: Bool = false) -> StepStatus {
        if awaiting { return .awaiting }
        if call.state == .error || call.isError {
            let text = (call.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if matches(interrupted, text) { return .cancelled }
            if matches(rejected, text) { return .rejected }
            return .failed
        }
        switch call.state {
        case .inputStreaming: return .pending
        case .running: return .running
        case .done, .error: return .succeeded
        }
    }

    /// Fold member statuses into one for a group row: anything live wins, then
    /// anything waiting on the user, then a failure; all-interrupted reads as
    /// interrupted.
    static func combine(_ statuses: [StepStatus]) -> StepStatus {
        if statuses.contains(where: \.isLive) { return .running }
        if statuses.contains(.awaiting) { return .awaiting }
        if statuses.contains(where: \.isFailure) { return .failed }
        if !statuses.isEmpty, statuses.allSatisfy({ $0 == .cancelled }) { return .cancelled }
        return .succeeded
    }
}
