import Foundation

/// A plan checklist read off a tool call — port of the web's
/// `src/lib/plan-parse.ts` (codeg 0.44) — so a persisted plan-like call
/// (Claude's `TodoWrite`, Kimi's `TodoList`, codex's `update_plan`) draws as
/// the same plan card the live stream's `plan_update` does, rather than as a
/// tool row. Also the reader of a plan-*mode* call's plan document.
///
/// Pure and dependency-free: the adapter (`MessageRender`), the live turn's
/// hand-off and the tool card all read through here, so they cannot disagree
/// on what a plan is.
enum PlanParse {
    /// The name of the call a turn handed off locally keeps its live plan as
    /// (`LiveTurn.snapshotAsMessageTurns`): the call Claude's transcript
    /// records a plan by, which `parseTodos` reads back.
    static let handoffToolName = "TodoWrite"

    /// Whether a call by `name` may carry a plan (web `isPlanLikeToolName`):
    /// `TodoWrite`, Kimi's `TodoList`, or anything with "plan" in it (codex's
    /// `update_plan`). Plan-mode transitions match too, harmlessly: their
    /// input holds a document or nothing, never entries, and only a call that
    /// yields some converts. So does an unrelated name that happens to embed
    /// the letters (`book_airplane`) — the same entries gate keeps it a call.
    static func isPlanLikeToolName(_ name: String) -> Bool {
        let n = normalizedName(name)
        return n == "todowrite" || n == "todolist" || n.contains("plan")
    }

    /// Lowercased, ASCII letters and digits only — separators and case never
    /// tell two spellings of a tool apart (web `normalizeToolName`).
    private static func normalizedName(_ name: String) -> String {
        // ASCII `a`–`z` and `0`–`9`, by byte: a multi-byte character never
        // has a byte in either range.
        let kept = name.lowercased().utf8.filter { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) }
        return String(decoding: kept, as: UTF8.self)
    }

    /// The checklist in a call's input: its `todos`, `entries` or `plan`
    /// array, the first that yields an entry (web `parseTodosFromJson`).
    /// Claude's `TodoWrite` writes `{todos: [{content, status, activeForm}]}`,
    /// Kimi's `TodoList` `{todos: [{title, status}]}`, codex's `update_plan`
    /// `{plan: [{step, status}], explanation}`. Empty for anything else — an
    /// `ExitPlanMode` plan is a document (`plan` is a string), not a list.
    static func parseTodos(_ input: String?) -> [PlanEntry] {
        guard let object = jsonObject(input) else { return [] }
        for key in ["todos", "entries", "plan"] {
            guard let list = object[key] as? [Any] else { continue }
            let found = entries(list)
            if !found.isEmpty { return found }
        }
        return []
    }

    /// One entry per item that names something (web `parsePlanEntriesArray`).
    /// The first of `content` / `step` / `title` / `name` that is a string
    /// names it — even a blank one, as the web reads it — and an item whose
    /// name is blank is skipped.
    static func entries(_ items: [Any]) -> [PlanEntry] {
        items.compactMap { item -> PlanEntry? in
            guard let record = item as? [String: Any] else { return nil }
            let content = (firstString(record, ["content", "step", "title", "name"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return PlanEntry(content: content,
                             priority: normalizePriority(record["priority"] as? String),
                             status: normalizeStatus(record["status"] as? String))
        }
    }

    /// The value of the first of `keys` that holds a string.
    private static func firstString(_ record: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = record[key] as? String { return value }
        }
        return nil
    }

    /// web `normalizeStatus`: the three render states, by their wire names.
    static func normalizeStatus(_ raw: String?) -> String {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "done": return "completed"
        case "in_progress", "in-progress", "in progress", "running", "active": return "in_progress"
        default: return "pending"
        }
    }

    /// web `normalizePriority`: `medium` unless it says otherwise.
    static func normalizePriority(_ raw: String?) -> String {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high", "urgent": return "high"
        case "low": return "low"
        default: return "medium"
        }
    }

    /// `entries` as the input of a `handoffToolName` call, which `parseTodos`
    /// reads back. Keys sorted, so the same plan always writes the same text —
    /// the folded turn is a render-cache key.
    static func handoffInput(_ entries: [PlanEntry]) -> String {
        let todos = entries.map { ["content": $0.content, "status": $0.status, "priority": $0.priority] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["todos": todos], options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: - Kimi's live todo write

    /// The statuses Kimi Code's `TodoListInputSchema` accepts.
    private static let kimiTodoStatuses: Set<String> = ["pending", "in_progress", "done"]

    /// The entries of a Kimi Code `TodoList` WRITE, or nil when the input is
    /// not one (web `kimiTodoWriteEntries`).
    ///
    /// Over ACP Kimi's call carries only a localized title ("Updating todo
    /// list") and `kind: "other"` — the name `TodoList` is never on the live
    /// wire — so the exact input shape is the identity:
    /// `{todos: [{title: <non-blank>, status: pending|in_progress|done}]}`.
    /// Deliberately stricter than `parseTodos`, so an unrelated tool that
    /// merely carries a `todos` argument is not taken for one. Nil for the
    /// read (`{}`) and clear (`{todos: []}`) forms.
    static func kimiTodoWriteEntries(_ input: String?) -> [PlanEntry]? {
        // Asked of every live call on every pass of the live tier: only an
        // input that names the key is worth parsing.
        guard let input, input.contains("todos"),
              let object = jsonObject(input),
              let todos = object["todos"] as? [Any], !todos.isEmpty else { return nil }
        let isKimiWrite = todos.allSatisfy { item in
            guard let record = item as? [String: Any],
                  let title = record["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let status = record["status"] as? String else { return false }
            return kimiTodoStatuses.contains(status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        // Every item names itself, so none is dropped: one entry per todo.
        return isKimiWrite ? entries(todos) : nil
    }

    // MARK: - Plan-mode documents

    /// The free-form plan markdown a plan-*mode* call carries — Claude's
    /// `ExitPlanMode` `{plan: "…"}` — read directly or one level into a
    /// `rawInput` / `raw_input` envelope some hosts wrap the arguments in
    /// (web `extractPlanMarkdown`). Nil when there is no non-blank one.
    static func planMarkdown(_ input: String?) -> String? {
        guard let object = jsonObject(input) else { return nil }
        if let plan = document(in: object) { return plan }
        let nested = (object["rawInput"] as? [String: Any]) ?? (object["raw_input"] as? [String: Any])
        return nested.flatMap(document(in:))
    }

    private static func document(in object: [String: Any]) -> String? {
        guard let plan = (object["plan"] ?? object["Plan"]) as? String,
              !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return plan
    }

    // MARK: - JSON

    /// A JSON object, or nil for anything else (an array, a bare value,
    /// invalid or empty text).
    private static func jsonObject(_ input: String?) -> [String: Any]? {
        guard let input, !input.isEmpty, let data = input.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
