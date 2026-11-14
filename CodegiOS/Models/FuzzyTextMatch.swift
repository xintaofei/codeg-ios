import Foundation

/// Ranked text matcher for the composer's slash-command / skill menus — a port
/// of web `src/lib/fuzzy-text-match.ts`. No external fuzzy dependency: tiers
/// are exact → prefix → substring → subsequence, so a short input like `bmhp`
/// still hits `bmad-help`. Within a tier an earlier match position and a
/// shorter candidate win.
///
/// JS semantics are kept on purpose: positions and lengths count UTF-16 code
/// units, and the subsequence walk compares code units — so a ranking on this
/// client is the ranking the web shows for the same list.
enum FuzzyTextMatch {
    private static let tierBase = 100_000_000
    private static let tierExact = 6
    private static let tierPrefix = 5
    private static let tierSubstring = 4
    private static let tierSubsequence = 3

    private static func tierScore(_ tier: Int, _ position: Int, _ length: Int) -> Int {
        tier * tierBase - min(position, 9_999) * 1_000 - min(length, 999)
    }

    /// Index of the first matched unit if every unit of `query` appears in `s`
    /// in order (a subsequence), else -1. `query` must be non-empty.
    static func subsequenceFirstIndex(_ query: String, _ s: String) -> Int {
        subsequenceFirstIndex(Array(query.utf16), Array(s.utf16))
    }

    private static func subsequenceFirstIndex(_ query: [UInt16], _ s: [UInt16]) -> Int {
        var qi = 0
        var firstIdx = -1
        var si = 0
        while si < s.count, qi < query.count {
            if s[si] == query[qi] {
                if qi == 0 { firstIdx = si }
                qi += 1
            }
            si += 1
        }
        return qi == query.count ? firstIdx : -1
    }

    /// Score one already-lowercased string against an already-lowercased,
    /// non-empty `query`. Higher is better; nil means no match.
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.utf16)
        guard !q.isEmpty else { return nil }
        let t = Array(text.utf16)
        if t == q { return tierScore(tierExact, 0, t.count) }
        if t.starts(with: q) { return tierScore(tierPrefix, 0, t.count) }
        if let idx = firstIndex(of: q, in: t) { return tierScore(tierSubstring, idx, t.count) }
        let sub = subsequenceFirstIndex(q, t)
        if sub != -1 { return tierScore(tierSubsequence, sub, t.count) }
        return nil
    }

    /// JS `String.prototype.indexOf` over code units.
    private static func firstIndex(of needle: [UInt16], in haystack: [UInt16]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var i = 0
        while i + needle.count <= haystack.count {
            if haystack[i] == needle[0], Array(haystack[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// Filter + rank `items` by a primary text, with an optional secondary
    /// field fallback (a description, a skill id). An empty query returns the
    /// items unchanged, in their original order. A secondary hit always ranks
    /// below every primary hit, and equal scores keep their input order.
    static func rank<T>(
        _ query: String,
        _ items: [T],
        primary: (T) -> String,
        secondary: ((T) -> String?)? = nil
    ) -> [T] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        // Below every primary tier, so a weak name subsequence still beats a
        // perfect description / id match.
        let secondaryOffset = tierExact * tierBase
        var scored: [(offset: Int, item: T, score: Int)] = []
        for (offset, item) in items.enumerated() {
            var value = score(q, primary(item).lowercased())
            if value == nil, let secondary, let text = secondary(item)?.lowercased(), !text.isEmpty,
               let sec = score(q, text) {
                value = sec - secondaryOffset
            }
            if let value { scored.append((offset, item, value)) }
        }
        // Stable: the input order breaks ties, like the web's ES2019 sort.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
        return scored.map(\.item)
    }
}
