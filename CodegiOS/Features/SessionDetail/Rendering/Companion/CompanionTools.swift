import Foundation

// Classifies the codeg-mcp "companion" tool calls an agent emits when it
// delegates work or asks the user a question, so each gets a dedicated card
// instead of the generic tool shell. Mirrors the web client's
// `isAgentLikeToolName` / `isDelegationStatusToolName` (tool-kind-classifier.ts)
// plus its input-shape inference (`inferLiveToolName`).
//
// DETECTION IS INPUT-SHAPE FIRST. On the persisted path a tool's raw name is the
// real MCP name (`mcp__codeg-mcp__delegate_to_agent`), so a name match is
// reliable. On the LIVE path the "name" is the ACP tool *title* — an arbitrary
// host/agent-supplied string with no `tool_name`/`meta` alongside it — so name
// matching fails. The backend itself recognizes a delegation by its argument
// shape (`is_delegation_invocation`: `task` + `agent_type` present), so we do the
// same and only fall back to the name suffix.

/// Which codeg-mcp companion tool a call represents. `nil` (the common case)
/// means an ordinary tool that renders through `ToolCallCard`.
enum CompanionKind: Equatable {
    case delegate           // delegate_to_agent
    case delegationStatus   // get_delegation_status
    case cancelDelegation   // cancel_delegation
    case askQuestion        // ask_user_question
}

enum CompanionDetect {

    /// Resolve a call's companion kind from its tool name and input. `parsed` is
    /// the pre-parsed object form (`ToolDerive.parseJSON`) reused when available;
    /// when it's nil (e.g. a top-level double-encoded `"{...}"` string, which
    /// `parseJSON` can't cast), fall back to `CompanionJSON.object(from:)`, which
    /// peels that layer — otherwise a live companion call with a free-form title
    /// would slip through to the generic card.
    static func kind(name: String, input: String?, parsed: [String: Any]?) -> CompanionKind? {
        // 1. Input shape — authoritative on both paths, and the only signal on
        //    the live path where `name` is a free-form title. Only the strong,
        //    unambiguous signatures resolve here. A bare `{ task_id }` is NOT one:
        //    it's `cancel_delegation`'s shape but also any number of unrelated
        //    task tools, so cancel is resolved by name (step 2) — mirroring the
        //    web, which never infers cancel from input.
        if let args = unwrapArgs(parsed ?? CompanionJSON.object(from: input)) {
            let hasTask = (args["task"] as? String)?.isEmpty == false
            let hasAgent = (args["agent_type"] as? String)?.isEmpty == false
            if hasTask && hasAgent { return .delegate }
            if args["task_ids"] is [Any] { return .delegationStatus }
            if args["wait_ms"] != nil, args["task_id"] != nil { return .delegationStatus }
            if args["questions"] is [Any] { return .askQuestion }
        }
        // 2. Name suffix — covers `cancel_delegation`, the persisted raw name, and
        //    a live call whose input hasn't streamed (or didn't match a shape above).
        return nameKind(name)
    }

    /// A `delegate_to_agent` call known only by the tool name the activity
    /// timeline classifies on (`ToolCallVM.toolName`), where neither the title
    /// nor the argument shape says so — so it gets the delegation card the
    /// timeline gives it a delegation step for:
    /// - an opencode code-mode `execute`, whose arguments ride inside the JS
    ///   `code` (``CodeModeDelegation``; `execute` normalizes to `bash`);
    /// - a live call identified by its `_meta` — the broker's
    ///   `codeg.delegation` stamp included, which turns a code-mode call's
    ///   inferred name into `delegate_to_agent` once it is registered.
    /// Mirrors the delegation arms of `DescribeToolCall.kind` — but the name
    /// alone is not enough for a card: a live call's inferred name can come
    /// from its title, which quotes anything (a Bash `rg 'delegate_to_agent'`
    /// would lose its command and output to a sub-agent card). So it counts
    /// only with a delegation's own evidence: the code-mode input, or a stamp
    /// in `_meta` (``ToolNameNormalizer/metaNamesDelegation(_:)``).
    static func delegateByToolName(_ toolName: String, input: String?, meta: AnyJSON?) -> CompanionKind? {
        // Runs on every `ToolCallVM` built, live passes included: the name
        // lookup is memoized, and the suffix test spares the regex.
        let name = ToolNameNormalizer.normalizeToolName(toolName).lowercased()
        if CodeModeDelegation.isCodeModeDelegationCall(normalizedToolName: name, input: input) { return .delegate }
        guard name.hasSuffix("delegate_to_agent"), ActivityToolFacts.isDelegateToAgentToolName(name) else { return nil }
        return CodeModeDelegation.isCodeModeDelegationInput(input) || ToolNameNormalizer.metaNamesDelegation(meta)
            ? .delegate : nil
    }

    /// Peel one or more wrapper objects (`arguments`/`input`/`params`/`payload`/
    /// `_meta`, incl. a double-encoded JSON string) to reach the object that
    /// actually carries the tool args. Mirrors web `findDelegationArgs` /
    /// `findTaskId` (depth-capped). Returns the first object bearing a
    /// discriminating key, else the top object unchanged.
    static func unwrapArgs(_ parsed: [String: Any]?, depth: Int = 0) -> [String: Any]? {
        guard depth <= 4, let parsed else { return nil }
        if discriminates(parsed) { return parsed }
        for key in ["arguments", "input", "params", "payload", "_meta"] {
            if let child = parsed[key] as? [String: Any], let found = unwrapArgs(child, depth: depth + 1) {
                return found
            }
            // Some hosts double-encode the input as a JSON string.
            if let s = parsed[key] as? String, let obj = ToolJSONFormat.parseObject(s),
               let found = unwrapArgs(obj, depth: depth + 1) {
                return found
            }
        }
        return parsed
    }

    private static func discriminates(_ obj: [String: Any]) -> Bool {
        for k in ["task", "agent_type", "task_ids", "task_id", "questions", "wait_ms"] where obj[k] != nil {
            return true
        }
        return false
    }

    /// Match a bare canonical name or any host-prefixed / separated form
    /// (`mcp__server__tool`, `server/tool`, `server.tool`, `server:tool`).
    static func nameKind(_ name: String) -> CompanionKind? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        if matches(n, "delegate_to_agent") { return .delegate }
        if matches(n, "get_delegation_status") { return .delegationStatus }
        if matches(n, "cancel_delegation") { return .cancelDelegation }
        if matches(n, "ask_user_question") { return .askQuestion }
        return nil
    }

    /// `name` equals `tool`, or ends with `tool` immediately after a
    /// non-alphanumeric separator. Mirrors the web suffix regex
    /// `(?:^|[^a-z0-9])<tool>$`.
    private static func matches(_ name: String, _ tool: String) -> Bool {
        if name == tool { return true }
        guard name.hasSuffix(tool), name.count > tool.count else { return false }
        let sepIndex = name.index(name.endIndex, offsetBy: -(tool.count + 1))
        let sep = name[sepIndex]
        return !sep.isLetter && !sep.isNumber
    }
}

/// Recovers a JSON object embedded in arbitrary text. Port of the web
/// `embedded-json.ts`: scan from the first `{` to a balanced `}`, shrinking from
/// the last `}` inward until a span parses. Used to pull a broker report out of
/// host wrappers — notably Codex's `"Wall time: N seconds\nOutput:\n<json>"`
/// (sometimes with a trailing terminal-cursor character) — that a direct parse
/// can't handle. Returns nil when no `{…}` substring parses.
enum EmbeddedJSON {
    static func extractObject(_ raw: String) -> [String: Any]? {
        let chars = Array(raw)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var end = chars.count - 1
        while end > start {
            if chars[end] == "}", let obj = ToolJSONFormat.parseObject(String(chars[start...end])) {
                return obj
            }
            end -= 1
        }
        return nil
    }
}

/// Shared JSON-object recovery for the companion parsers: a direct object parse,
/// a double-encoded JSON string (`"{...}"`), or an object embedded in
/// surrounding text. Mirrors the leniency of the web parsers' parse chains.
enum CompanionJSON {
    static func object(from raw: String?) -> [String: Any]? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let obj = ToolJSONFormat.parseObject(raw) { return obj }
        if let any = ToolJSONFormat.parseAny(raw), let s = any as? String, let obj = ToolJSONFormat.parseObject(s) {
            return obj
        }
        return EmbeddedJSON.extractObject(raw)
    }

    /// A JSON value that is genuinely a boolean (not a 0/1 number). JSONSerialization
    /// models both as `NSNumber`; `ToolJSONFormat.isBoolean` discriminates via CF type.
    static func bool(_ value: Any?) -> Bool? {
        guard let value, ToolJSONFormat.isBoolean(value), let n = value as? NSNumber else { return nil }
        return n.boolValue
    }
}

/// Peels the host envelopes that wrap an MCP `CallToolResult` on its way to a
/// tool card. Port of the web `mcp-result-envelope.ts`.
///
/// codex-acp forwards EVERY MCP tool call's outcome to the ACP wire as
/// `rawOutput = { result: <CallToolResult> | null, error: <string> | null }`, and
/// codex's own rollout tags the same result under a serde `{ Ok: … }` variant.
/// Neither layer is part of the result the codeg-mcp companion returned, so a card
/// that reads a companion result has to strip them first — otherwise the whole
/// envelope falls through as opaque text and the card renders raw JSON (with the
/// badge falling back to the tool lifecycle, reporting "done" for tasks that are
/// still running).
///
/// The peel is deliberately narrow: a tool result is only ever a *child agent's*
/// arbitrary payload away from being mangled, so both the destination and the
/// failure case are positively identified rather than matched on key names alone.
/// A payload that merely happens to own a `result` or `error` key is left exactly
/// as it was.
enum McpResultEnvelope {
    /// Keys a host uses to nest the actual `CallToolResult`. `result` is
    /// codex-acp's live-wire envelope; `Ok`/`ok` the serde-tagged `Result` variant
    /// codex writes into its rollout.
    private static let wrapperKeys = ["result", "Ok", "ok"]
    /// One host layer plus a serde tag is the deepest shape seen.
    private static let maxDepth = 3

    struct Peeled {
        /// The `CallToolResult` reached by peeling, or the input unchanged when no
        /// host envelope was positively identified.
        let obj: [String: Any]
        /// codex-acp's `rawOutput.error`, read ONLY from an envelope carrying a
        /// `result` key with nothing in it — i.e. the MCP call failed outright and
        /// that string is all there is to show.
        let hostError: String?
    }

    /// Strip host `{ result, error }` / `{ Ok }` layers from `obj`.
    ///
    /// - Parameter isResolvable: the caller's own "I can already read this shape"
    ///   predicate. Peeling stops as soon as it holds, so a `CallToolResult` that
    ///   itself owns a `result` key is never unwrapped out from under the caller.
    static func peel(_ obj: [String: Any], isResolvable: ([String: Any]) -> Bool) -> Peeled {
        var current = obj
        var depth = 0
        while depth < maxDepth, !isResolvable(current) {
            var next: [String: Any]?
            for key in wrapperKeys {
                if let value = current[key] as? [String: Any], isCallToolResult(value) {
                    next = value
                    break
                }
            }
            // Nothing peelable left: this is either the payload itself or a host
            // envelope whose call failed before producing a result.
            guard let next else { return Peeled(obj: current, hostError: hostFailureError(current)) }
            current = next
            depth += 1
        }
        return Peeled(obj: current, hostError: nil)
    }

    /// Whether `value` is an MCP `CallToolResult` — the only thing worth peeling
    /// TO. Requiring this of the destination (not just the wrapper key's presence)
    /// is what keeps a child's own `{result: {...}}` payload from being unwrapped
    /// and then misread as a report.
    private static func isCallToolResult(_ value: [String: Any]) -> Bool {
        if value["content"] is [Any] { return true }
        return value["structuredContent"] is [String: Any]
    }

    /// The error string of a host FAILURE envelope — `{result: null, error: "…"}`.
    /// codex-acp always emits both keys, so requiring a present-but-empty `result`
    /// alongside the string is what separates a failed MCP call from a child
    /// payload that merely has an `error` field of its own.
    private static func hostFailureError(_ obj: [String: Any]) -> String? {
        guard obj.keys.contains("result") else { return nil }
        // `JSONSerialization` models a JSON null as `NSNull`; a missing value is
        // absent from the dictionary. Both count as "no result".
        if let value = obj["result"], !(value is NSNull) { return nil }
        guard let err = obj["error"] as? String,
              !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return err
    }
}

/// Minimal NSRegularExpression capture helper for the line/text parsing the
/// companion parsers do (the broker's human-readable result shapes).
enum Rx {
    /// The first match's capture groups (1-based, `groups` of them), or nil if no
    /// match. An unmatched optional group yields "".
    static func capture(_ text: String, _ pattern: String, groups: Int, caseInsensitive: Bool = false) -> [String]? {
        let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1...max(groups, 1)).map { g in
            let r = m.range(at: g)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}
