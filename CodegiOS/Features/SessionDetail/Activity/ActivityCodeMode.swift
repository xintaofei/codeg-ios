import Foundation

/// One call a code-mode script made, as OpenCode reports it (web `CodeModeCall`).
struct CodeModeCall: Equatable, Hashable, Sendable {
    enum Status: String, Equatable, Hashable, Sendable {
        case running, completed, error
    }
    /// The catalog path the script called: `probe.echo`, `codeg-mcp.ask_user_question`.
    var tool: String
    var status: Status
    /// The call's arguments as the agent shows them; nil when not reported.
    var input: [String: AnyJSON]?
}

/// A script row's source, whichever agent ran it (web `ScriptCard`).
struct ScriptCard: Equatable, Hashable, Sendable {
    /// The script, as the agent ran it.
    var source: String
    /// Best-effort one-line title; nil when nothing reads as one.
    var title: String?
    /// `tools.*` call sites the agent counted; 0 when it did not count.
    var callCount: Int
}

/// Code-mode scripts: tool calls an agent makes by running a script that calls
/// its tools, rendered as one "Script" row — port of the web's
/// `src/lib/activity/code-mode.ts` (codeg 0.44).
///
/// Two shapes reach the row:
/// - codex's synthetic `codex_script` card (`{source, title, call_count}`), for a
///   script its history parser could not decompose;
/// - OpenCode 2's `execute` tool (`{code}`), which runs every MCP tool by
///   default. Its name normalizes to `bash` live and in history alike, so the
///   input shape is what tells it from a command — the same rule the code-mode
///   delegation check uses.
///
/// The calls a script made ride the call's `_meta` under ``callsMetaKey``,
/// agent-neutral: whoever writes them (the live backend from OpenCode's
/// `rawOutput.metadata.toolCalls`, a history parser from the stored call)
/// writes this shape.
enum ActivityCodeMode {
    /// `_meta` key carrying the calls a code-mode script made, an array of
    /// ``CodeModeCall``. Backend twin: `CODE_MODE_CALLS_META_KEY` in
    /// `src-tauri/src/acp/connection.rs`.
    static let callsMetaKey = "codeg.codeModeCalls"

    /// The script of an OpenCode code-mode `execute` call: its input is `{code}`
    /// and carries nothing a command does, so a command card would show an empty
    /// command line. Nil for any other input.
    static func codeModeScriptSource(_ input: String?) -> String? {
        guard let input, !input.isEmpty, input.contains("\"code\""),
              let parsed = ActivityJSON.tryParse(input),
              let code = parsed["code"] as? String,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        // `key in parsed`: present at all, even as null.
        for key in ["command", "cmd", "script", "args", "argv"] where parsed[key] != nil {
            return nil
        }
        return code
    }

    /// Whether a call that normalized to `bash` is really a code-mode script.
    /// `execute` normalizes to `bash`, so the input shape decides.
    static func isCodeModeScriptCall(normalizedToolName: String, input: String?) -> Bool {
        normalizedToolName == "bash" && codeModeScriptSource(input) != nil
    }

    /// The calls recorded on a call's `_meta` (see ``callsMetaKey``).
    ///
    /// iOS decodes `meta` with `.convertFromSnakeCase`, which leaves the dotted
    /// meta key and the call's own `tool`/`status`/`input` keys intact (but
    /// camel-cases the keys inside each `input`).
    static func codeModeCalls(_ meta: AnyJSON?) -> [CodeModeCall] {
        guard case .object(let record)? = meta,
              case .array(let list)? = record[callsMetaKey] else { return [] }
        var calls: [CodeModeCall] = []
        for item in list {
            guard case .object(let call) = item else { continue }
            let tool = call["tool"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if tool.isEmpty { continue }
            let status = call["status"]?.string.flatMap(CodeModeCall.Status.init(rawValue:)) ?? .running
            calls.append(CodeModeCall(tool: tool, status: status, input: call["input"]?.object))
        }
        return calls
    }

    /// ``codeModeCalls(_:)`` for a `JSONSerialization` meta (keys verbatim).
    static func codeModeCalls(rawMeta: [String: Any]?) -> [CodeModeCall] {
        guard let rawMeta else { return [] }
        return codeModeCalls(AnyJSON(any: rawMeta))
    }

    /// codex's synthetic `codex_script` card (web `parseCodexScriptCard`, from
    /// `src/lib/codex-code-mode.ts`). Re-ported here rather than reusing
    /// `CodexScriptCard.parse`, which reads a boolean or fractional
    /// `call_count` as a number.
    static func parseCodexScriptCard(_ input: String?) -> ScriptCard? {
        guard let input, !input.isEmpty,
              let record = ActivityJSON.tryParse(input),
              let source = record["source"] as? String else { return nil }
        let count = ActivityJSON.number(record["call_count"])
        return ScriptCard(
            source: source,
            title: record["title"] as? String,
            callCount: count.map(countValue) ?? 0
        )
    }

    /// A script row's card: codex's synthetic card, or an OpenCode `execute`
    /// call's script. The title names the tools the script called when they are
    /// known — what the user wants from a row that only runs other tools — and
    /// otherwise its first line.
    static func parseScriptCard(_ input: String?, meta: AnyJSON?) -> ScriptCard? {
        if let codex = parseCodexScriptCard(input) { return codex }
        guard let source = codeModeScriptSource(input) else { return nil }
        let calls = codeModeCalls(meta)
        var seen = Set<String>()
        let tools = calls.map(\.tool).filter { seen.insert($0).inserted }
        return ScriptCard(
            source: source,
            title: tools.isEmpty ? firstCodeLine(source) : tools.joined(separator: ", "),
            callCount: calls.count
        )
    }

    /// ``parseScriptCard(_:meta:)`` for a `JSONSerialization` meta.
    static func parseScriptCard(_ input: String?, rawMeta: [String: Any]?) -> ScriptCard? {
        parseScriptCard(input, meta: rawMeta.map { AnyJSON(any: $0) })
    }

    /// The first line of a script that says something.
    private static func firstCodeLine(_ source: String) -> String? {
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("//") { return trimmed }
        }
        return nil
    }

    /// The web keeps any finite `call_count` as is; a count is whole in
    /// practice, so a fraction truncates and an out-of-range value reads as 0.
    private static func countValue(_ value: Double) -> Int {
        guard value.isFinite, abs(value) < 9_007_199_254_740_992 else { return 0 }
        return Int(value)
    }
}
