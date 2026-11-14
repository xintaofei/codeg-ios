import Foundation

/// Background tasks a command left running and the calls that later poll
/// them — port of the web's `src/lib/background-task.ts` (codeg 0.44).
///
/// Claude Code starts a background shell with `Bash(run_in_background: true)`,
/// whose result is a launch line carrying the task id ("Command running in
/// background with ID: <id>. …" — read by
/// `ActivityToolFacts.backgroundLaunchTaskId`). The agent then polls with
/// `TaskOutput({task_id, block, timeout})`, whose result is an XML-tagged
/// envelope, and may finally `TaskStop({task_id})`, whose result is a JSON
/// object carrying the original command:
///
///     poll → <retrieval_status>success|timeout|not_ready</retrieval_status>
///            <task_id>…</task_id> <task_type>local_bash</task_type>
///            <status>running|completed</status> <exit_code>0</exit_code>
///            <output>…(ANSI shell output)…</output>
///     stop → {"message":"Successfully stopped task: … (<command>)",
///             "task_id":…, "task_type":…, "command":…}
///
/// Grok reports the same lifecycle as a JSON envelope (`{"type":"TaskOutput",
/// "Result":{task_id, command, status, exit_code, output, …}}`, also
/// `MultiResult`, and `SubagentCompleted` for a polled sub-agent), and
/// CodeBuddy as a plain-text snapshot (`Task ID: …` / `Shell ID: …`).
///
/// The same task is polled again and again (first timeout/running, then
/// success/completed), so a run of polls draws as ONE lane — a row per task,
/// its latest poll speaking for it — the way delegation polls do.
///
/// ADAPTATION: a `ToolCallVM` has no separate `errorText` channel; an error
/// result rides in `output` with `isError` set, so the web's `output ??
/// errorText` is `output` and "errored" is `isError`. The web's "unsettled"
/// call (a live state, or a forwarded ACP status that is not terminal) is a
/// `.running` / `.inputStreaming` state here: the adapters fold a call's
/// status into its state (`MessageRender.toolState`, `adaptLive`).
enum BackgroundTask {
    private typealias JS = ActivityCommand.JS

    /// One task as one tool result reported it.
    struct Envelope: Equatable, Sendable {
        enum Kind: String, Sendable {
            /// A `TaskOutput` retrieval.
            case poll
            /// A `TaskStop` acknowledgement (or a task that was ended).
            case stop
        }
        var kind: Kind
        /// Whether THIS poll fetched fresh data: success | timeout | not_ready.
        var retrievalStatus: String?
        var taskId: String?
        /// e.g. `local_bash`, `local_workflow`, `subagent`.
        var taskType: String?
        /// running | completed (poll); `stopped` for a stop.
        var status: String?
        var exitCode: Int?
        /// Shell output (may hold ANSI escapes).
        var output: String?
        /// The original command (a stop's, Grok's, CodeBuddy's shell).
        var command: String?
        /// A stop's acknowledgement.
        var message: String?
    }

    enum Badge: String, Sendable {
        case running, completed, failed, stopped
    }

    /// One task of a lane: the latest poll's outcome plus the freshest output
    /// and command gathered across every poll of that task id.
    struct Row: Equatable, Sendable, Identifiable {
        var key: String
        var taskId: String?
        var taskType: String?
        var badge: Badge
        /// The latest poll is still in flight with nothing back yet.
        var isInFlight: Bool
        var exitCode: Int?
        var output: String?
        var command: String?
        /// How many polls fold into this row.
        var pollCount: Int
        /// A sub-agent rather than a background shell: its output is a prose
        /// report (Markdown), not a terminal stream.
        var isSubagent: Bool

        var id: String { key }
    }

    // MARK: - Claude Code poll / stop

    private static func tag(_ name: String) -> NSRegularExpression {
        JS.regex("<\(name)>([\\s\\S]*?)</\(name)>", ignoreCase: true)
    }
    private static let retrievalStatusTag = tag("retrieval_status")
    private static let taskTypeTag = tag("task_type")
    private static let taskIdTag = tag("task_id")
    private static let statusTag = tag("status")
    private static let exitCodeTag = tag("exit_code")
    /// Greedy to the LAST close, so shell output that itself holds `<…>`
    /// fragments is not cut short.
    private static let outputTag = JS.regex(#"<output>([\s\S]*)</output>"#, ignoreCase: true)
    /// A tag a Claude Code poll envelope cannot do without.
    private static let pollTag = JS.regex(#"<(?:retrieval_status|task_type|task_id)>"#, ignoreCase: true)
    private static let stoppedPhrase = JS.regex("successfully stopped task", ignoreCase: true)

    /// A single `<name>…</name>` tag (first match), trimmed.
    private static func xmlTag(_ re: NSRegularExpression, _ text: String) -> String? {
        guard let groups = JS.match(re, text), groups.count > 1, let inner = groups[1] else { return nil }
        return JS.trim(inner)
    }

    /// `<output>…</output>` with the envelope's own wrapping newlines taken
    /// off (`/^\r?\n/` and `/\r?\n[ \t]*$/`); the content is kept as it is.
    private static func xmlOutputTag(_ text: String) -> String? {
        guard let groups = JS.match(outputTag, text), groups.count > 1, let inner = groups[1] else { return nil }
        var scalars = Array(inner.unicodeScalars)
        if scalars.first == "\n" {
            scalars.removeFirst()
        } else if scalars.count >= 2, scalars[0] == "\r", scalars[1] == "\n" {
            scalars.removeFirst(2)
        }
        var end = scalars.count
        while end > 0, scalars[end - 1] == " " || scalars[end - 1] == "\t" { end -= 1 }
        if end > 0, scalars[end - 1] == "\n" {
            end -= 1
            if end > 0, scalars[end - 1] == "\r" { end -= 1 }
            scalars.removeSubrange(end...)
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// `/^-?\d+$/.test(raw) ? parseInt(raw, 10) : null` (`\d` is ASCII).
    private static func parseExitCode(_ raw: String) -> Int? {
        var digits = raw.unicodeScalars[...]
        if digits.first == "-" { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(raw)
    }

    private static func parsePoll(_ text: String) -> Envelope? {
        let retrievalStatus = xmlTag(retrievalStatusTag, text)
        let taskType = xmlTag(taskTypeTag, text)
        let taskId = xmlTag(taskIdTag, text)
        let status = xmlTag(statusTag, text)
        // At least one envelope-defining tag, so text that merely holds a
        // stray `<task_id>` is not read as a poll.
        if retrievalStatus == nil, taskType == nil, !(taskId != nil && status != nil) { return nil }
        return Envelope(kind: .poll, retrievalStatus: retrievalStatus, taskId: taskId, taskType: taskType,
                        status: status, exitCode: xmlTag(exitCodeTag, text).flatMap(parseExitCode),
                        output: xmlOutputTag(text), command: nil, message: nil)
    }

    private static func parseStop(_ text: String) -> Envelope? {
        guard let obj = ActivityJSON.tryParse(text) else { return nil }
        let message = obj["message"] as? String
        let command = obj["command"] as? String
        let taskId = obj["task_id"] as? String
        let taskType = obj["task_type"] as? String
        // Strict, so other JSON results are not taken: the phrase first, the
        // id + command + message + type shape for wording drift.
        let looksLikeStop = message.map { JS.test(stoppedPhrase, $0) } == true
            || (taskId != nil && command != nil && message != nil && taskType != nil)
        guard looksLikeStop else { return nil }
        return Envelope(kind: .stop, retrievalStatus: nil, taskId: taskId, taskType: taskType,
                        status: "stopped", exitCode: nil, output: nil, command: command, message: message)
    }

    // MARK: - Grok

    /// Statuses Grok reports for a task that was ended rather than allowed to
    /// finish — the `stop` kind, so the row reads "stopped".
    private static let grokStoppedStatuses: Set<String> = ["killed", "stopped", "cancelled", "canceled"]

    private static func lowerTrim(_ s: String) -> String {
        ToolNameNormalizer.jsLower(JS.trim(s))
    }

    /// One Grok `TaskOutputResult`; `status` is kept as it came (lower-cased).
    private static func grokResultToEnvelope(_ result: [String: Any]) -> Envelope? {
        let taskId = result["task_id"] as? String
        let command = result["command"] as? String
        let status = (result["status"] as? String).map(lowerTrim)
        // Something identifying, so a stray `{type:"TaskOutput"}` is no row.
        if taskId == nil, command == nil, status == nil { return nil }
        return Envelope(kind: status.map { grokStoppedStatuses.contains($0) } == true ? .stop : .poll,
                        retrievalStatus: nil, taskId: taskId, taskType: nil, status: status,
                        exitCode: ActivityJSON.int(result["exit_code"]),
                        output: result["output"] as? String, command: command, message: nil)
    }

    /// The result objects of a Grok `TaskOutput` envelope: `Result` (one
    /// task), `MultiResult` (the first array of objects in it — its field
    /// names are not pinned by any capture), `TaskNotFound` (none).
    ///
    /// ADAPTATION: JavaScript takes `MultiResult`'s first array in insertion
    /// order; a `JSONSerialization` object has none, so it is the first in key
    /// order. They differ only for a `MultiResult` with two arrays.
    private static func grokResultObjects(_ envelope: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let result = envelope["Result"] as? [String: Any] { out.append(result) }
        if let multi = envelope["MultiResult"] as? [String: Any] {
            for (_, value) in ActivityJSON.orderedEntries(multi) {
                guard let array = value as? [Any] else { continue }
                out.append(contentsOf: array.compactMap { $0 as? [String: Any] })
                break
            }
        }
        return out
    }

    /// Grok 0.2.11x's flat `SubagentCompleted` — what a poll of a background
    /// SUB-AGENT returns. Its command reads like 0.2.9x's
    /// `[subagent:<type>] <description>`, so both eras draw the same row.
    private static func grokSubagentCompleted(_ envelope: [String: Any]) -> Envelope? {
        func str(_ value: Any?) -> String? {
            guard let s = value as? String, !s.isEmpty else { return nil }
            return s
        }
        let taskId = str(envelope["subagent_id"])
        let status = str(envelope["status"]).map(lowerTrim)
        let output = str(envelope["output"]) ?? str(envelope["result"])
        if taskId == nil, status == nil, output == nil { return nil }
        let label = str(envelope["subagent_type"]).map { "[subagent:\($0)]" }
        let description = str(envelope["description"])
        let command: String?
        if let label, let description { command = "\(label) \(description)" } else { command = label ?? description }
        return Envelope(kind: status.map { grokStoppedStatuses.contains($0) } == true ? .stop : .poll,
                        retrievalStatus: nil, taskId: taskId, taskType: "subagent", status: status,
                        exitCode: nil, output: output, command: command, message: nil)
    }

    /// A Grok `get_command_or_subagent_output` result. Strict on `type`, so
    /// other JSON output is never taken; a truncated envelope is no envelope.
    private static func parseGrokTaskOutput(_ text: String) -> [Envelope] {
        guard JS.startsWith(text, "{"), let envelope = ActivityJSON.tryParse(text) else { return [] }
        let type = envelope["type"] as? String
        if type == "SubagentCompleted" { return grokSubagentCompleted(envelope).map { [$0] } ?? [] }
        guard type == "TaskOutput" else { return [] }
        return grokResultObjects(envelope).compactMap(grokResultToEnvelope)
    }

    // MARK: - CodeBuddy

    /// Statuses CodeBuddy reports for an ended task — the `stop` kind.
    private static let codeBuddyStoppedStatuses: Set<String> = ["cancelled", "canceled", "killed"]
    /// The `<system-reminder data-role="tool-hint">` block CodeBuddy appends
    /// to a still-running snapshot — addressed to the model. (JavaScript's
    /// ASCII `\b` spelled as a look-ahead.)
    private static let codeBuddyToolHint = JS.regex(
        #"<system-reminder(?![A-Za-z0-9_])[\s\S]*?</system-reminder>"#, ignoreCase: true)
    /// Separates an agent snapshot's header (and its `Prompt:` / `Response:`
    /// echoes) from the worker's own report.
    private static let codeBuddyResultSeparator = "--- RESULT ---"

    /// `Label: value` off `line`, or nil.
    private static func labeledLine(_ line: String?, _ label: String) -> String? {
        guard let line else { return nil }
        let prefix = "\(label): "
        guard JS.startsWith(line, prefix) else { return nil }
        let value = JS.trim(JS.sliceScalars(line, dropFirst: prefix.unicodeScalars.count, dropLast: 0))
        return value.isEmpty ? nil : value
    }

    private static func cleanCodeBuddyBody(_ body: String) -> String? {
        let cleaned = JS.trim(replaceAll(codeBuddyToolHint, in: body, with: ""))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// A CodeBuddy `TaskOutput` snapshot — plain text, two shapes:
    ///
    ///     agent → Task ID: … / Status: … / … / --- RESULT --- / <report>
    ///     shell → Shell ID: … / Command: … / Status: … / Duration: … /
    ///             Timestamp: … / (blank) / Stdout (full): … / Stderr …
    ///
    /// The agent shape shows only the `--- RESULT ---` tail (the `Response:`
    /// above it repeats it). The shell shape is only read when its header can
    /// be located with certainty (`shellHeaderIsUnambiguous`).
    private static func parseCodeBuddySnapshot(_ text: String) -> Envelope? {
        let lines = JS.split(text, "\n")
        func line(_ i: Int) -> String? { i < lines.count ? lines[i] : nil }
        func statusOf(_ raw: String?) -> String? { raw.map(lowerTrim) }
        func kind(_ status: String?) -> Envelope.Kind {
            status.map { codeBuddyStoppedStatuses.contains($0) } == true ? .stop : .poll
        }

        if let agentId = labeledLine(line(0), "Task ID") {
            guard let agentStatus = statusOf(labeledLine(line(1), "Status")) else { return nil }
            // No separator: a team-member snapshot, whose whole body is the
            // note after the two header lines.
            let start = lines.firstIndex(of: codeBuddyResultSeparator).map { $0 + 1 } ?? 2
            return Envelope(kind: kind(agentStatus), retrievalStatus: nil, taskId: agentId, taskType: "subagent",
                            status: agentStatus, exitCode: nil,
                            output: cleanCodeBuddyBody(lines.dropFirst(start).joined(separator: "\n")),
                            command: nil, message: nil)
        }

        guard let shellId = labeledLine(line(0), "Shell ID") else { return nil }
        guard let command = labeledLine(line(1), "Command"), shellHeaderIsUnambiguous(lines) else { return nil }
        let shellStatus = statusOf(labeledLine(line(2), "Status"))
        // No exit code in a shell snapshot: none is invented. The output is
        // everything from the `Stdout` line on — stdout and stderr, in order.
        return Envelope(kind: kind(shellStatus), retrievalStatus: nil, taskId: shellId, taskType: "local_bash",
                        status: shellStatus, exitCode: nil,
                        output: cleanCodeBuddyBody(lines.dropFirst(6).joined(separator: "\n")),
                        command: command, message: nil)
    }

    /// The header's closing run sits at its fixed offset (line 2) AND nowhere
    /// else. The command and the output are both arbitrary text, so a second
    /// candidate makes the boundary undecidable — and then nothing is claimed
    /// rather than a truncated command and a status lifted from the output.
    private static func shellHeaderIsUnambiguous(_ lines: [String]) -> Bool {
        guard shellHeaderRunAt(lines, 2) else { return false }
        for i in stride(from: 3, to: lines.count, by: 1) where shellHeaderRunAt(lines, i) { return false }
        return true
    }

    /// `Status:` / `Duration:` / `Timestamp:` / blank / `Stdout…` from `i`.
    private static func shellHeaderRunAt(_ lines: [String], _ i: Int) -> Bool {
        func line(_ j: Int) -> String { j < lines.count ? lines[j] : "" }
        guard i + 3 < lines.count else { return false }
        return JS.startsWith(line(i), "Status: ")
            && JS.startsWith(line(i + 1), "Duration: ")
            && JS.startsWith(line(i + 2), "Timestamp: ")
            && JS.trim(lines[i + 3]).isEmpty
            && JS.startsWith(line(i + 4), "Stdout")
    }

    // MARK: - Envelopes

    /// Every task one background-task result reports: one envelope for
    /// Claude Code's poll / stop and CodeBuddy's snapshot, one per task for
    /// Grok's `TaskOutput`. Empty when the text is none of them.
    static func parseEnvelopes(_ text: String?) -> [Envelope] {
        guard let text else { return [] }
        // This runs on every tool call's result as a reply is adapted, and the
        // parsers are not cheap. Each shape is recognizable up front — before
        // the text is even copied — so ordinary output skips them all.
        let scalars = text.unicodeScalars
        guard let start = scalars.firstIndex(where: { !JS.isWhitespace($0) }) else { return [] }
        let head = scalars[start...]
        let json = head.first == "{"
        let codeBuddy = head.starts(with: "Task ID: ".unicodeScalars) || head.starts(with: "Shell ID: ".unicodeScalars)
        // The tags hold no whitespace, so testing the untrimmed text is the same.
        let pollTagged = JS.test(pollTag, text)
        guard json || codeBuddy || pollTagged else { return [] }
        let raw = JS.trim(text)
        let single = (pollTagged ? parsePoll(raw) : nil)
            ?? (json ? parseStop(raw) : nil)
            ?? (codeBuddy ? parseCodeBuddySnapshot(raw) : nil)
        if let single { return [single] }
        return json ? parseGrokTaskOutput(raw) : []
    }

    /// The first task a result reports, or nil.
    static func parseEnvelope(_ text: String?) -> Envelope? {
        parseEnvelopes(text).first
    }

    // MARK: - Which calls

    /// Matched on the activity tool name (`ToolCallVM.toolName`).
    private static let toolNames: Set<String> = ["taskoutput", "taskstop", "task_output", "task_stop"]

    /// Still in flight: running, or its arguments still streaming. (The web's
    /// `isUnsettledToolCall` and `isInFlightState`, which iOS's states fold
    /// into one — see the type's note.)
    private static func isInFlight(_ call: ToolCallVM) -> Bool {
        call.state == .running || call.state == .inputStreaming
    }

    private static func inputObject(_ input: String?) -> [String: Any]? {
        guard let input, !input.isEmpty else { return nil }
        return ActivityJSON.tryParse(input)
    }

    /// A poll's input: Claude Code's `{task_id, block?, timeout?}` or Grok's
    /// `{task_ids: [...], timeout_ms}`. The block / timeout keys tell it from
    /// `cancel_delegation` / `TaskStop` (a bare `{task_id}`) and
    /// `get_delegation_status` (`{task_ids, wait_ms}`); a `subagent_type`
    /// rules out a real sub-agent call.
    private static func inputIsPoll(_ input: String?) -> Bool {
        guard let obj = inputObject(input) else { return false }
        if obj["subagent_type"] != nil { return false }
        if let taskId = obj["task_id"] as? String, !taskId.isEmpty {
            return obj["block"] != nil || obj["timeout"] != nil
        }
        guard let ids = obj["task_ids"] as? [Any], !ids.isEmpty, ids.allSatisfy({ $0 is String }) else { return false }
        return obj["timeout_ms"] != nil
    }

    /// Whether a call is a background-task poll or stop: named `TaskOutput` /
    /// `TaskStop` (Claude Code's own path); its result parses as an envelope
    /// (a live alias, Grok's JSON, CodeBuddy's text, any naming); or it has a
    /// poll's input and is still in flight. Never a real sub-agent call,
    /// `get_delegation_status` or `cancel_delegation`.
    ///
    /// The input shape claims only a call in flight: Grok's
    /// `get_command_or_subagent_output` polls commands and sub-agents with the
    /// same arguments, so once it settles its result alone decides — an
    /// unknown result falls back to a plain row rather than a lane row stuck
    /// on "running".
    static func isToolCall(_ call: ToolCallVM) -> Bool {
        if toolNames.contains(lowerTrim(call.toolName)) { return true }
        if !parseEnvelopes(call.output).isEmpty { return true }
        return inputIsPoll(call.input) && isInFlight(call)
    }

    // MARK: - Rows

    /// The task a poll was called for: `task_id`, or Grok's one-task
    /// `task_ids` (which lets an in-flight poll join its settled sibling).
    private static func inputTaskId(_ input: String?) -> String? {
        guard let obj = inputObject(input) else { return nil }
        if let id = obj["task_id"] as? String, !id.isEmpty { return id }
        if let ids = obj["task_ids"] as? [Any], ids.count == 1, let id = ids[0] as? String, !id.isEmpty { return id }
        return nil
    }

    private static func badge(_ envelope: Envelope?, _ poll: ToolCallVM) -> Badge {
        if envelope?.kind == .stop { return .stopped }
        // Grok says how it ended in `status`; checked before `completed` so a
        // failure with no exit code (a spawn error) is not a success.
        if envelope?.status == "failed" { return .failed }
        if let envelope, envelope.status == "completed" {
            return envelope.exitCode.map { $0 != 0 } == true ? .failed : .completed
        }
        // An errored poll with no clean "completed" envelope is a failure.
        if poll.isError { return .failed }
        // running / timeout / not_ready / no envelope yet.
        return .running
    }

    /// `[subagent:<type>] …` — Grok 0.2.9x's pseudo-command for a sub-agent.
    private static let grokSubagentCommandPrefix = "[subagent:"

    private static func isSubagentRow(taskType: String?, command: String?) -> Bool {
        if taskType == "subagent" { return true }
        return command.map { JS.startsWith(JS.trimStart($0), grokSubagentCommandPrefix) } == true
    }

    private struct Entry {
        let poll: ToolCallVM
        let envelope: Envelope?
    }

    /// A run of polls → one row per task, in first-seen order. A poll belongs
    /// to its envelope's task id, else its input's, so a task polled N times
    /// is one row with its latest outcome and parallel tasks are one row each.
    static func buildRows(_ polls: [ToolCallVM]) -> [Row] {
        var order: [String] = []
        var byKey: [String: (taskId: String?, entries: [Entry])] = [:]

        func record(_ poll: ToolCallVM, _ envelope: Envelope?) {
            let taskId = envelope?.taskId ?? inputTaskId(poll.input)
            // A live poll whose `task_id` has not streamed in yet (an arg-less
            // initial `tool_call`) would stack an anonymous "running" row per
            // re-poll; it joins its task's row once the id arrives.
            if taskId == nil, envelope == nil, isInFlight(poll) { return }
            let key = taskId ?? "__bg__:\(poll.id)"
            if byKey[key] == nil {
                byKey[key] = (taskId, [])
                order.append(key)
            }
            byKey[key]?.entries.append(Entry(poll: poll, envelope: envelope))
        }

        for poll in polls {
            // One poll can report several tasks (Grok's `MultiResult`).
            let envelopes = parseEnvelopes(poll.output)
            if envelopes.isEmpty {
                record(poll, nil)
            } else {
                for envelope in envelopes { record(poll, envelope) }
            }
        }

        return order.compactMap { key -> Row? in
            guard let entry = byKey[key], let latest = entry.entries.last else { return nil }
            let envelope = latest.envelope
            // The terminal poll carries the full output; an in-flight last poll
            // must not blank a run an earlier poll captured.
            var output: String?
            var command: String?
            var taskType: String?
            for item in entry.entries {
                if let o = item.envelope?.output, !JS.trim(o).isEmpty { output = o }
                if let c = item.envelope?.command, !c.isEmpty { command = c }
                if let t = item.envelope?.taskType, !t.isEmpty { taskType = t }
            }
            let isSubagent = isSubagentRow(taskType: taskType, command: command)
            return Row(key: key, taskId: entry.taskId, taskType: taskType,
                       badge: badge(envelope, latest.poll),
                       isInFlight: isInFlight(latest.poll) && envelope?.output == nil,
                       exitCode: envelope?.exitCode,
                       output: isSubagent ? stripGrokSubagentScaffolding(output) : output,
                       command: command, pollCount: entry.entries.count, isSubagent: isSubagent)
        }
    }

    private static let subagentMeta = JS.regex(#"<subagent_meta>[\s\S]*?</subagent_meta>"#, ignoreCase: true)
    private static let subagentResult = JS.regex(#"<subagent_result>[\s\S]*?</subagent_result>"#, ignoreCase: true)
    private static let blankLineRun = JS.regex(#"\n{3,}"#)

    /// Drop what Grok appends to a POLLED sub-agent's report for the parent
    /// model (`<subagent_meta>…`, `<subagent_result>… resume_from=…`). Output
    /// without them comes back as it was.
    static func stripGrokSubagentScaffolding(_ output: String?) -> String? {
        guard let output, !output.isEmpty else { return output }
        let stripped = replaceAll(subagentResult, in: replaceAll(subagentMeta, in: output, with: ""), with: "")
        if stripped.utf16.elementsEqual(output.utf16) { return output }
        // The tags sit at the end: close the blank lines they leave.
        return JS.trimEnd(replaceAll(blankLineRun, in: stripped, with: "\n\n"))
    }

    // MARK: - Status

    /// The lane's status (web `backgroundStatus`): any task running, then any
    /// failed; every task stopped is interrupted.
    static func status(_ rows: [Row]) -> StepStatus {
        if rows.contains(where: { $0.badge == .running }) { return .running }
        if rows.contains(where: { $0.badge == .failed }) { return .failed }
        if !rows.isEmpty, rows.allSatisfy({ $0.badge == .stopped }) { return .cancelled }
        return .succeeded
    }

    /// One row's status. A settled poll that said "still running" is a
    /// snapshot, not live work: only a poll in flight is running.
    static func rowStatus(_ row: Row) -> StepStatus {
        switch row.badge {
        case .completed: return .succeeded
        case .failed: return .failed
        case .stopped: return .cancelled
        case .running: return row.isInFlight ? .running : .succeeded
        }
    }

    /// Kept in view while its reply is folded: its newest poll is still in
    /// flight (web `BackgroundTaskRows` under `pinnedOnly`).
    static func staysInView(_ row: Row) -> Bool {
        row.badge == .running && row.isInFlight
    }

    // MARK: - Row text (web `BackgroundTaskRowView`)

    /// The task id as the row shows it.
    static func shortId(_ row: Row) -> String? {
        row.taskId.map { String($0.prefix(9)) }
    }

    /// What the row shows of the task's output. iOS draws no ANSI colours,
    /// so the escapes are taken out of a shell's output (a sub-agent's report
    /// is prose and has none).
    static func displayOutput(_ row: Row) -> String? {
        guard let output = row.output else { return nil }
        return row.isSubagent ? output : replaceAll(ansiEscape, in: output, with: "")
    }

    private static let ansiEscape = JS.regex(#"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#)

    /// `Regenerate audit report · report.md written` — what started the task
    /// (the launching command's description, else its first line), then what
    /// it came to: a failure's last line, a success's first.
    static func rowDetail(_ row: Row, launch: BackgroundLaunch?) -> String? {
        let what = launch?.description ?? (row.isSubagent ? nil : firstLine(launch?.command ?? row.command))
        let output = displayOutput(row)
        let result: String?
        switch row.badge {
        case .running: result = nil
        case .failed: result = lastLine(output)
        case .completed, .stopped: result = firstLine(output)
        }
        let parts = [what, result].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func nonBlankLines(_ text: String?) -> [String] {
        guard let text else { return [] }
        return JS.split(text, "\n").map(JS.trim).filter { !$0.isEmpty }
    }

    static func firstLine(_ text: String?) -> String? {
        nonBlankLines(text).first.map { String($0.prefix(160)) }
    }

    static func lastLine(_ text: String?) -> String? {
        nonBlankLines(text).last.map { String($0.prefix(160)) }
    }

    // MARK: - Helpers

    /// `s.replace(re /g, template)`.
    private static func replaceAll(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                    withTemplate: template)
    }
}

/// A command that moved its process to the background, as its task's row
/// names it (web `BackgroundLaunch`).
struct BackgroundLaunch: Equatable, Sendable {
    /// The launching command's step.
    var stepKey: String
    var command: String
    /// The agent's own one-line description of the command.
    var description: String?
}
