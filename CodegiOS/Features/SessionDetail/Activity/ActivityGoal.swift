import Foundation

/// What a Codex `/goal`'s calls say about the goal — the pure half of the
/// web's `goal-tool-call.tsx` (codeg 0.44): the objective, its status, its
/// token budget and time, read from `create_goal` and the closing
/// `update_goal`, and how the goal row words them.
enum ActivityGoal {
    struct Facts: Equatable {
        var objective: String?
        /// As the agent wrote it; `GoalStatus.of` reads it.
        var status: String?
        var tokensUsed: Double?
        var tokenBudget: Double?
        var timeUsedSeconds: Double?
        var remainingTokens: Double?
    }

    /// The goal as its calls describe it, the closing call's word first
    /// (web `parseGoal`).
    static func facts(start: ToolCallVM, end: ToolCallVM?) -> Facts {
        let startInput = object(start.input)
        let startOutput = object(start.output)
        let endInput = object(end?.input)
        let endOutput = object(end?.output)
        let startGoal = startOutput?["goal"] as? [String: Any]
        let endGoal = endOutput?["goal"] as? [String: Any]
        let tokenKeys = ["tokensUsed", "tokens_used"]
        let budgetKeys = ["tokenBudget", "token_budget"]
        let timeKeys = ["timeUsedSeconds", "time_used_seconds"]
        let remainingKeys = ["remainingTokens", "remaining_tokens"]
        return Facts(
            objective: nonBlankString(endGoal, "objective")
                ?? nonBlankString(endInput, "objective")
                ?? nonBlankString(startGoal, "objective")
                ?? nonBlankString(startInput, "objective"),
            status: nonBlankString(endGoal, "status")
                ?? nonBlankString(endInput, "status")
                ?? nonBlankString(startGoal, "status")
                ?? nonBlankString(startInput, "status")
                ?? (ToolNameNormalizer.normalizeToolName(start.toolName) == "create_goal" ? "active" : nil),
            tokensUsed: number(endGoal, tokenKeys) ?? number(startGoal, tokenKeys),
            tokenBudget: number(endGoal, budgetKeys) ?? number(startGoal, budgetKeys)
                ?? number(startInput, budgetKeys),
            timeUsedSeconds: number(endGoal, timeKeys) ?? number(startGoal, timeKeys),
            remainingTokens: number(endOutput, remainingKeys) ?? number(startOutput, remainingKeys))
    }

    /// Either goal call failed.
    static func isError(start: ToolCallVM, end: ToolCallVM?) -> Bool {
        start.isError || end?.isError == true
    }

    /// The failure to show: the closing call's, else the opening call's, with
    /// a fence around the whole text lifted.
    static func errorText(start: ToolCallVM, end: ToolCallVM?) -> String? {
        let raw = (end?.isError == true ? end?.output : nil) ?? (start.isError ? start.output : nil)
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return unwrapWholeFence(raw)
    }

    // MARK: - Status

    enum Status: Equatable {
        case active, paused, blocked, usageLimited, budgetLimited, limited, complete
        /// A status the row has no word for: shown as the agent wrote it.
        case other(String)

        /// What the row colours it as (web `statusTone`).
        enum Tone { case active, complete, error, muted }

        static func of(_ status: String?) -> Status? {
            guard let status else { return nil }
            switch ToolNameNormalizer.normalizeGoalStatus(status) {
            case "active": return .active
            case "paused": return .paused
            case "blocked": return .blocked
            case "usage_limited": return .usageLimited
            case "budget_limited": return .budgetLimited
            // Neutral goal-extension snapshots (claude-agent-acp 0.66+ /
            // codex-acp 1.2+) collapse the two limits into one adapter-side.
            case "limited": return .limited
            case "complete", "completed": return .complete
            default: return .other(status)
            }
        }

        var tone: Tone {
            switch self {
            case .active: return .active
            case .complete: return .complete
            case .blocked, .usageLimited, .budgetLimited, .limited: return .error
            case .paused: return .muted
            case .other(let raw):
                return ToolNameNormalizer.normalizeGoalStatus(raw) == "failed" ? .error : .muted
            }
        }
    }

    // MARK: - Formatting (web `formatTokens` / `formatDuration`)

    /// `5.2K`, `512`: a token count without its unit.
    static func compactTokens(_ count: Double) -> String {
        if Swift.abs(count) >= 1000 {
            return dropTrailingZero(toFixed1(count / 1000)) + "K"
        }
        return jsNumber(count)
    }

    /// `19s`, `1.5m`, `2h`.
    static func duration(seconds: Double) -> String {
        if seconds < 60 { return "\(jsNumber(jsRound(seconds)))s" }
        let minutes = seconds / 60
        if minutes < 60 { return dropTrailingZero(toFixed1(minutes)) + "m" }
        return dropTrailingZero(toFixed1(minutes / 60)) + "h"
    }

    // MARK: - JSON

    /// A trimmed, non-blank string field (web `stringField`).
    static func nonBlankString(_ obj: [String: Any]?, _ key: String) -> String? {
        guard let value = obj?[key] as? String else { return nil }
        let trimmed = ToolNameNormalizer.jsTrim(value)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ obj: [String: Any]?, _ keys: [String]) -> Double? {
        for key in keys {
            if let value = ActivityJSON.number(obj?[key]), value.isFinite { return value }
        }
        return nil
    }

    private static func object(_ raw: String?) -> [String: Any]? {
        guard let raw, !raw.isEmpty else { return nil }
        return ActivityJSON.tryParse(raw)
    }

    // MARK: - Fences (web `unwrapWholeFence`)

    /// The text a single code fence wraps, when that fence wraps all of
    /// `text`; `text` itself otherwise. claude-agent-acp fences every failed
    /// tool's result for markdown clients; the row shows it preformatted.
    static func unwrapWholeFence(_ text: String) -> String {
        let trimmed = ToolNameNormalizer.jsTrim(text)
        let ns = trimmed as NSString
        guard let match = wholeFenceRE.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
              match.range(at: 1).location != NSNotFound, match.range(at: 2).location != NSNotFound
        else { return text }
        let fence = ns.substring(with: match.range(at: 1))
        let body = ns.substring(with: match.range(at: 2))
        // Only when no line inside could close the fence first.
        let closesEarly = body.components(separatedBy: "\n").contains { line in
            jsTrimStart(line).hasPrefix(fence)
        }
        return closesEarly ? text : body
    }

    /// `^[ \t]*(`{3,})[^`\n]*\n([\s\S]*?)\n[ \t]*\1[ \t]*$` — JS `$` is the
    /// end of the input (no multiline flag), hence `\z`.
    private static let wholeFenceRE = try! NSRegularExpression(
        pattern: #"\A[ \t]*(`{3,})[^`\n]*\n([\s\S]*?)\n[ \t]*\1[ \t]*\z"#)

    private static func jsTrimStart(_ s: String) -> String {
        // `trimStart` strips the same set `trim` does, from the front only.
        let trimmed = ToolNameNormalizer.jsTrim(s + "x")
        return String(trimmed.dropLast())
    }

    // MARK: - JS number formatting

    /// `x.toFixed(1)`: the n whose n/10 is nearest x, a tie going to the
    /// larger magnitude — decided on x's exact value, as JS does (`%.1f`
    /// breaks a tie to even).
    static func toFixed1(_ x: Double) -> String {
        let a = Swift.abs(x)
        // Beyond what a goal carries; JS switches to exponents there anyway.
        guard a.isFinite, a < 1e14 else { return String(format: "%.1f", x) }
        var n = (a * 10).rounded(.down)
        // `a * 10` rounds: settle n so that n ≤ 10a < n + 1, exactly.
        // `addingProduct` is a fused multiply-add — one rounding, so the sign
        // of each difference is exact.
        while n > 0, n.addingProduct(-a, 10) > 0 { n -= 1 }      // n > 10a
        while (n + 1).addingProduct(-a, 10) <= 0 { n += 1 }      // n + 1 ≤ 10a
        // Round half up: 10a − n ≥ ½ ⇔ 2n + 1 − 20a ≤ 0.
        if (2 * n + 1).addingProduct(-a, 20) <= 0 { n += 1 }
        let digits = String(Int(n))
        let padded = digits.count < 2 ? "0" + digits : digits
        let whole = String(padded.dropLast())
        let tenth = String(padded.suffix(1))
        return (x < 0 ? "-" : "") + whole + "." + tenth
    }

    private static func dropTrailingZero(_ fixed: String) -> String {
        fixed.hasSuffix(".0") ? String(fixed.dropLast(2)) : fixed
    }

    /// `Math.round`: half toward +∞.
    private static func jsRound(_ x: Double) -> Double {
        let down = x.rounded(.down)
        return x - down >= 0.5 ? down + 1 : down
    }

    /// A number as JS prints it, for the values a goal carries.
    private static func jsNumber(_ x: Double) -> String {
        if x == 0 { return "0" }   // `-0` prints as `0`
        if x == x.rounded(), Swift.abs(x) < 1e15 { return String(Int(x)) }
        return "\(x)"
    }
}
