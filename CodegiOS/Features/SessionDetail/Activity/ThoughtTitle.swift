import Foundation

/// A one-line title for a reasoning block, so a folded thought still says what
/// it was about ("Thought · Summarizing log status") instead of a bare
/// "Thought" — port of the web's `src/lib/activity/thought.ts` (codeg 0.44).
///
/// Models that write reasoning summaries open each section with a heading —
/// a whole line of bold (`**Planning the fix**`) or an ATX heading. While the
/// block is still being written the newest heading is the live topic; once it
/// is done the first one names it, since later headings are steps inside it.
/// Reasoning without headings falls back to its first sentence.
///
/// Title length is counted in `Character`s where the web counts UTF-16 code
/// units (as `ActivityFormat.ellipsis` does); they differ only for astral
/// characters such as emoji, which this way are never cut in half.
enum ThoughtTitle {
    static let maxTitleLength = 60

    // The regexes spell out JS semantics for ICU: `.` (no `s` flag) stops only
    // at \n \r \u2028 \u2029, and `$` (no `m` flag) is the end of input (`\z`).
    private static let jsDot = #"[^\n\r\u2028\u2029]"#
    private static let boldLineRe = try! NSRegularExpression(
        pattern: #"^\s*(?:\*\*|__)("# + jsDot + #"+?)(?:\*\*|__)\s*:?\s*\z"#
    )
    private static let atxHeadingRe = try! NSRegularExpression(
        pattern: #"^\s{0,3}#{1,6}\s+("# + jsDot + #"+?)\s*#*\s*\z"#
    )
    private static let indentedFenceRe = try! NSRegularExpression(pattern: #"^\s*(?:```|~~~)"#)
    private static let fenceRe = try! NSRegularExpression(pattern: #"^(?:```|~~~)"#)
    private static let sentenceEndRe = try! NSRegularExpression(pattern: #"[.!?。！？](?=\s|\z)"#)

    static func thoughtTitle(_ content: String, streaming: Bool) -> String? {
        if trim(content).isEmpty { return nil }
        let found = headings(content)
        if let title = streaming ? found.last : found.first {
            return clip(title)
        }
        return firstSentence(content).map(clip)
    }

    /// The thought's body with the heading the title already shows taken off the
    /// top, so the expanded panel does not repeat the row it hangs under.
    static func thoughtBodyWithoutTitle(_ content: String, title: String?) -> String {
        guard let title, !title.isEmpty else { return content }
        let lines = content.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !trim($0).isEmpty }) else { return content }
        guard let heading = headingText(lines[first]),
              clip(cleanInline(heading)) == title else { return content }
        return lines[(first + 1)...]
            .joined(separator: "\n")
            .replacingOccurrences(of: #"^\s*\n"#, with: "", options: .regularExpression)
    }

    /// What a thought row shows (web `ThoughtRow`): its title, and the panel it
    /// opens onto — the reasoning minus the heading the title came from,
    /// trimmed. An empty `body` means the row has nothing to open.
    static func row(_ content: String, streaming: Bool) -> (title: String?, body: String) {
        let title = thoughtTitle(content, streaming: streaming)
        return (title, trim(thoughtBodyWithoutTitle(content, title: title)))
    }

    // MARK: - Helpers

    private static func cleanInline(_ text: String) -> String {
        trim(
            text.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\*\*|__"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        )
    }

    private static func clip(_ text: String) -> String {
        if text.count <= maxTitleLength { return text }
        var head = String(text.prefix(maxTitleLength - 1))
        while let last = head.last, last.isWhitespace { head.removeLast() }
        return head + "…"
    }

    /// The text of a whole-line bold or ATX heading, before inline cleanup.
    private static func headingText(_ line: String) -> String? {
        firstCapture(boldLineRe, line) ?? firstCapture(atxHeadingRe, line)
    }

    private static func headings(_ content: String) -> [String] {
        var found: [String] = []
        var inFence = false
        for line in content.components(separatedBy: "\n") {
            if matches(indentedFenceRe, line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            guard let heading = headingText(line) else { continue }
            let title = cleanInline(heading)
            if !title.isEmpty { found.append(title) }
        }
        return found
    }

    private static func firstSentence(_ content: String) -> String? {
        guard let text = content.components(separatedBy: "\n")
            .map(trim)
            .first(where: { !$0.isEmpty && !matches(fenceRe, $0) })
        else { return nil }
        let plain = cleanInline(
            text.replacingOccurrences(of: #"^[-*+>]\s+"#, with: "", options: .regularExpression)
        )
        if plain.isEmpty { return nil }
        let ns = plain as NSString
        let end = sentenceEndRe.firstMatch(in: plain, range: NSRange(location: 0, length: ns.length))?.range.location
        // `search` is a UTF-16 offset; slice the same way.
        if let end, end > 0 { return ns.substring(to: end) }
        return plain
    }

    /// JavaScript's `trim()`.
    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
        re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func firstCapture(_ re: NSRegularExpression, _ text: String) -> String? {
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
