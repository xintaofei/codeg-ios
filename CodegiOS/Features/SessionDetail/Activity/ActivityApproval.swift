import Foundation

/// How one tool call's permission request was answered (web `ToolApprovalInfo`,
/// Rust `ToolApprovalInfo`): live on the `tool_approval` event and the
/// snapshot's `tool_approvals`, and kept by the backend for reopened
/// conversations.
///
/// Its properties are the camelCase forms of the wire's snake_case keys, so it
/// decodes through the app's shared `.convertFromSnakeCase` decoder. Only the
/// call and the option kind are required; the rest only annotate the chip.
struct ToolApprovalInfo: Decodable, Equatable, Hashable, Sendable {
    var toolCallId: String
    /// The chosen option's ACP kind (`allow_once`, `allow_always`,
    /// `reject_once`, `reject_always`), verbatim.
    var optionKind: String
    /// The chosen option's label in the agent's own words.
    var optionName: String
    /// `PermissionAnswerOrigin.kind` of whoever answered.
    var origin: String
    /// ISO timestamp.
    var decidedAt: String

    init(toolCallId: String, optionKind: String, optionName: String, origin: String, decidedAt: String) {
        self.toolCallId = toolCallId
        self.optionKind = optionKind
        self.optionName = optionName
        self.origin = origin
        self.decidedAt = decidedAt
    }

    private enum CodingKeys: String, CodingKey { case toolCallId, optionKind, optionName, origin, decidedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try c.decode(String.self, forKey: .toolCallId)
        optionKind = try c.decode(String.self, forKey: .optionKind)
        optionName = ((try? c.decodeIfPresent(String.self, forKey: .optionName)) ?? nil) ?? ""
        origin = ((try? c.decodeIfPresent(String.self, forKey: .origin)) ?? nil) ?? ""
        decidedAt = ((try? c.decodeIfPresent(String.self, forKey: .decidedAt)) ?? nil) ?? ""
    }
}

/// A connection's approval records, by tool call id (web `ToolApprovalMap`).
typealias ToolApprovalMap = [String: ToolApprovalInfo]

/// How a tool call's permission request was answered, as the transcript draws
/// it: a chip on the call's row — port of the web's
/// `src/lib/activity/approval.ts` (codeg 0.44). Built from the live
/// `tool_approval` record (the connection's own) or from the
/// `meta["codeg.approval"]` stamp a reopened conversation's detail load puts on
/// the call.
///
/// `allow_once` / `allow_always` / a rejection: ACP has `reject_once` and
/// `reject_always`; both turned this call away, which is what the row says.
enum ActivityApproval {
    /// Where a detail load stamps a call's approval (Rust `APPROVAL_META_KEY`).
    static let approvalMetaKey = "codeg.approval"

    static let emptyToolApprovals: ToolApprovalMap = [:]

    /// The approval a detail load stamped on a tool call's `meta`, if any.
    ///
    /// iOS decodes `meta` with `.convertFromSnakeCase`: the dotted key survives,
    /// but the stamp's own keys arrive camelCased (`optionKind`), so each field
    /// is read under its wire spelling first and its decoded one second.
    static func approvalFromMeta(_ meta: AnyJSON?) -> ToolApproval? {
        guard case .object(let outer)? = meta,
              case .object(let stamp)? = outer[approvalMetaKey] else { return nil }
        return fromFields { key in
            (stamp[key] ?? stamp[camelCased(key)])?.string
        }
    }

    /// ``approvalFromMeta(_:)`` for a `JSONSerialization` meta, whose keys are
    /// verbatim (snake_case only, as on the web).
    static func approvalFromMeta(rawMeta: [String: Any]?) -> ToolApproval? {
        guard let stamp = rawMeta?[approvalMetaKey] as? [String: Any] else { return nil }
        return fromFields { stamp[$0] as? String }
    }

    /// A live record as the transcript draws it.
    ///
    /// The web caches the result per record object so a row's approval keeps
    /// its identity across renders; a Swift value compares by value, so there
    /// is nothing to cache.
    static func approvalFromInfo(_ info: ToolApprovalInfo) -> ToolApproval? {
        fromFields { key in
            switch key {
            case "option_kind": return info.optionKind
            case "option_name": return info.optionName
            case "origin": return info.origin
            case "decided_at": return info.decidedAt
            default: return nil
            }
        }
    }

    /// Fold records into a connection's map: one per tool call, the later
    /// decision winning. Idempotent and order-free, so a snapshot older than the
    /// events already applied can only add calls this client never saw
    /// answered, never walk one back. Returns `current` unchanged when nothing
    /// changed.
    static func mergeToolApprovals(_ current: ToolApprovalMap, _ incoming: [ToolApprovalInfo]?) -> ToolApprovalMap {
        guard let incoming, !incoming.isEmpty else { return current }
        var next = current
        for info in incoming {
            if let known = next[info.toolCallId], decidedAtMs(known) >= decidedAtMs(info) { continue }
            next[info.toolCallId] = info
        }
        return next
    }

    // MARK: - Helpers

    private static func decisionOf(_ kind: String?) -> ToolApproval.Decision? {
        switch kind {
        case "allow_once": return .allowOnce
        case "allow_always": return .allowAlways
        case "reject_once", "reject_always": return .rejected
        default: return nil
        }
    }

    /// A string that is not blank, kept as is.
    private static func text(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// `fields` reads one snake_case field as a string (nil when absent or not
    /// a string).
    private static func fromFields(_ fields: (String) -> String?) -> ToolApproval? {
        guard let decision = decisionOf(fields("option_kind")) else { return nil }
        return ToolApproval(
            decision: decision,
            optionName: text(fields("option_name")),
            origin: text(fields("origin")),
            decidedAt: text(fields("decided_at"))
        )
    }

    /// What `.convertFromSnakeCase` makes of a snake_case key: `option_kind` →
    /// `optionKind`.
    private static func camelCased(_ key: String) -> String {
        let parts = key.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return key }
        return String(parts[0]) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    private static func decidedAtMs(_ info: ToolApprovalInfo) -> Int64 {
        parseDateMs(info.decidedAt) ?? 0
    }

    private static let isoDateTime = try! NSRegularExpression(pattern:
        #"^([+-]\d{6}|\d{4})(?:-(\d{2})(?:-(\d{2}))?)?"#
        + #"(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?)?"#
        + #"(Z|[+-]\d{2}(?::?\d{2})?)?\z"#
    )

    /// JavaScript's `Date.parse` for the ISO 8601 forms codeg writes, in whole
    /// milliseconds: a date alone is UTC, a date and time without an offset is
    /// local time. Nil (the web's `NaN`) for anything else.
    static func parseDateMs(_ string: String) -> Int64? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = s as NSString
        guard let m = isoDateTime.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let year = group(1).flatMap({ Int($0) }) else { return nil }
        let month = group(2).flatMap { Int($0) } ?? 1
        let day = group(3).flatMap { Int($0) } ?? 1
        let hasTime = group(4) != nil
        let hour = group(4).flatMap { Int($0) } ?? 0
        let minute = group(5).flatMap { Int($0) } ?? 0
        let second = group(6).flatMap { Int($0) } ?? 0
        // Only milliseconds count: further digits are dropped, as V8 does.
        let millis = group(7).map { Int(($0 + "00").prefix(3)) ?? 0 } ?? 0
        guard (1...12).contains(month), (1...31).contains(day),
              hour <= 24, minute <= 59, second <= 59,
              hour < 24 || (minute == 0 && second == 0 && millis == 0) else { return nil }

        let zone: TimeZone
        if let offset = group(8) {
            if offset == "Z" {
                zone = TimeZone(secondsFromGMT: 0)!
            } else {
                let digits = offset.dropFirst().replacingOccurrences(of: ":", with: "")
                let hh = Int(digits.prefix(2)) ?? 0
                let mm = digits.count > 2 ? Int(digits.suffix(2)) ?? 0 : 0
                let seconds = (hh * 3600 + mm * 60) * (offset.hasPrefix("-") ? -1 : 1)
                guard let tz = TimeZone(secondsFromGMT: seconds) else { return nil }
                zone = tz
            }
        } else {
            zone = hasTime ? .current : TimeZone(secondsFromGMT: 0)!
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded()) + Int64(millis)
    }
}
