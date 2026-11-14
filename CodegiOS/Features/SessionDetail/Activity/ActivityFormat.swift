import Foundation

/// Display formatting shared by the activity timeline — port of the web's
/// `src/lib/activity/format.ts` (codeg 0.44).
///
/// Lengths are counted in `Character`s where the web counts UTF-16 code units;
/// the two agree for the ASCII paths and commands these see, and Characters
/// never cut a grapheme in half.
enum ActivityFormat {
    /// The separator a path uses: a backslash when it has one, else a slash —
    /// a bare drive (`C:`) counts as Windows. Mirrors `fsSeparator`.
    static func fsSeparator(_ path: String) -> String {
        if path.contains("\\") { return "\\" }
        if path.contains("/") { return "/" }
        return path.range(of: #"^[A-Za-z]:$"#, options: .regularExpression) != nil ? "\\" : "/"
    }

    /// Shorten a path to its last two segments, rejoined with the path's own
    /// separator. Agents on Windows report backslash paths, so both split.
    static func shortPath(_ p: String) -> String {
        let segments = p.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        if segments.count <= 2 { return p }
        return segments.suffix(2).joined(separator: fsSeparator(p))
    }

    /// Truncate to `maxLen`, ending in "…" when it was cut.
    static func ellipsis(_ s: String, _ maxLen: Int) -> String {
        s.count > maxLen ? String(s.prefix(maxLen - 1)) + "…" : s
    }

    /// A path split into a muted directory (keeping its trailing separator) and
    /// a prominent file name; the halves concatenate back to the input minus
    /// any trailing separators.
    static func splitPathForDisplay(_ path: String) -> (dir: String, name: String) {
        var trimmed = path
        while let last = trimmed.last, last == "/" || last == "\\" { trimmed.removeLast() }
        guard let index = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) else {
            return ("", trimmed)
        }
        let after = trimmed.index(after: index)
        return (String(trimmed[..<after]), String(trimmed[after...]))
    }

    /// Lines in a block of text, not counting one trailing newline.
    static func countLines(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        var count = 1
        for scalar in text.unicodeScalars where scalar == "\n" { count += 1 }
        // By scalar, not `hasSuffix`: "\r\n" is ONE Character, so a CRLF text
        // would never read as ending in a newline.
        return text.unicodeScalars.last == "\n" ? count - 1 : count
    }

    /// The first non-blank line of a Markdown text with the inline syntax a
    /// one-line preview should not show taken off, clipped to `maxLength`.
    static func previewLine(_ text: String?, _ maxLength: Int) -> String? {
        guard let text else { return nil }
        for raw in text.components(separatedBy: "\n") {
            var l = raw
            l = l.replacingOccurrences(of: #"^\s*(?:#{1,6}\s+|[-*+]\s+|>\s*)"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            l = l.replacingOccurrences(of: #"(\*\*|__)(.+?)\1"#, with: "$2", options: .regularExpression)
            l = l.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
            l = l.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            return l.count > maxLength ? String(l.prefix(maxLength - 1)) + "…" : l
        }
        return nil
    }
}
