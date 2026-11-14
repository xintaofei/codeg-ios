import Foundation

/// Codex Plan-mode `<proposed_plan>…</proposed_plan>` blocks, lifted out of an
/// assistant text block into plan cards — port of the web's
/// `expandProposedPlanText` (`src/lib/adapters/ai-elements-adapter.ts`, codeg
/// 0.44). Pure: no view or live-model state, so the persisted adapter and the
/// live text leaf run the very same rule.
///
/// The rule, exactly as the web's:
/// * an opener counts only when it starts its own line (at most three columns
///   of indent, a tab being four) and is not inside markdown code — a fenced
///   block or an inline code span. Quoting the tag is not emitting it;
/// * the closer is held to the code rule alone: an unrecognised closer would
///   drag the trailing prose into the card, which is worse than a card that
///   ends early;
/// * prose before and after a block stays prose (dropped when blank);
/// * an unclosed block takes the rest of the text — a growing card while the
///   reply streams, a plain card (or nothing, when empty) once it has settled;
/// * several blocks in one text each become a card;
/// * text whose every tag is only quoted yields `nil`, so it renders verbatim.
///
/// Indices are UTF-16 code units, as in JS. Every slice point is an ASCII tag,
/// newline, or backtick boundary, so no surrogate pair is ever cut.
enum ProposedPlan {
    enum Segment: Equatable, Hashable {
        case text(String)
        /// `streaming`: the block is still open and the reply still streams.
        case plan(markdown: String, streaming: Bool)
    }

    static let openTag = "<proposed_plan>"
    static let closeTag = "</proposed_plan>"

    private typealias Units = [UInt16]
    private static let open = Units(openTag.utf16)
    private static let close = Units(closeTag.utf16)

    private static let newline: UInt16 = 0x0A
    private static let carriageReturn: UInt16 = 0x0D
    private static let backtick: UInt16 = 0x60
    private static let tilde: UInt16 = 0x7E
    private static let space: UInt16 = 0x20
    private static let tab: UInt16 = 0x09

    /// The segments of `text`, or nil when it holds no real plan block.
    static func extract(_ text: String, isStreaming: Bool) -> [Segment]? {
        // The common case — no tag at all — costs one byte scan, no copy.
        guard containsOpenTag(text) else { return nil }
        let units = Units(text.utf16)

        let codeSpans = markdownCodeSpans(units)
        var segments: [Segment] = []
        var cursor = 0
        var sawPlan = false

        while true {
            var openAt = indexOutsideCode(units, open, from: cursor, codeSpans)
            while let at = openAt, !opensOwnLine(units, at) {
                openAt = indexOutsideCode(units, open, from: at + open.count, codeSpans)
            }
            guard let start = openAt else { break }
            sawPlan = true

            let lead = string(units, cursor, start)
            if !ToolNameNormalizer.jsTrim(lead).isEmpty { segments.append(.text(lead)) }

            let bodyStart = start + open.count
            let closeAt = indexOutsideCode(units, close, from: bodyStart, codeSpans)
            let body = ToolNameNormalizer.jsTrim(string(units, bodyStart, closeAt ?? units.count))
            let streamingCard = closeAt == nil && isStreaming
            if !body.isEmpty || streamingCard {
                segments.append(.plan(markdown: body, streaming: streamingCard))
            }

            guard let end = closeAt else {
                cursor = units.count
                break
            }
            cursor = end + close.count
        }

        let trail = string(units, cursor, units.count)
        if !ToolNameNormalizer.jsTrim(trail).isEmpty { segments.append(.text(trail)) }

        return sawPlan ? segments : nil
    }

    // MARK: - Markdown code

    /// A `[start, end)` range of code units.
    private typealias Range = (start: Int, end: Int)

    /// The ranges markdown renders as literal code: fenced blocks and inline
    /// code spans. Inline spans are matched within a single line only, so a
    /// stray unbalanced backtick marks nothing rather than masking a real plan
    /// further down.
    private static func markdownCodeSpans(_ text: Units) -> [Range] {
        var spans: [Range] = []
        var fence: (char: UInt16, length: Int, start: Int)?
        var lineStart = 0

        while true {
            let newlineAt = indexOf(text, newline, from: lineStart)
            let lineEnd = newlineAt ?? text.count
            // A CRLF line keeps its `\r`; the web's `.` never matches it, so the
            // fence is matched against the line without it.
            let contentEnd = lineEnd > lineStart && text[lineEnd - 1] == carriageReturn ? lineEnd - 1 : lineEnd
            let marker = fenceMarker(text, lineStart, contentEnd)

            if let open = fence {
                // A closing fence repeats the opener's character at least as
                // many times, with nothing but whitespace after it.
                if let marker, marker.char == open.char, marker.length >= open.length,
                   ToolNameNormalizer.jsTrim(string(text, marker.infoStart, contentEnd)).isEmpty {
                    spans.append((open.start, lineEnd))
                    fence = nil
                }
            } else if let marker {
                fence = (marker.char, marker.length, lineStart)
            } else {
                collectInlineCodeSpans(text, lineStart, contentEnd, &spans)
            }

            guard let at = newlineAt else { break }
            lineStart = at + 1
        }

        // An unclosed fence runs to the end of the block, as the renderer shows it.
        if let open = fence { spans.append((open.start, text.count)) }
        return spans
    }

    /// `/^ {0,3}(`{3,}|~{3,})(.*)$/` on `text[start, end)`: the fence character,
    /// its run length, and where the rest of the line begins. JS `.` matches no
    /// line terminator, so a rest holding one (`\r`, U+2028, U+2029) is no match.
    private static func fenceMarker(_ text: Units, _ start: Int, _ end: Int)
        -> (char: UInt16, length: Int, infoStart: Int)? {
        var index = start
        while index < end, text[index] == space { index += 1 }
        guard index - start <= 3, index < end else { return nil }
        let char = text[index]
        guard char == backtick || char == tilde else { return nil }
        let runStart = index
        while index < end, text[index] == char { index += 1 }
        guard index - runStart >= 3 else { return nil }
        if text[index..<end].contains(where: { $0 == carriageReturn || $0 == 0x2028 || $0 == 0x2029 }) {
            return nil
        }
        return (char, index - runStart, index)
    }

    /// Append the inline code spans of `text[lineStart, lineEnd)`. A run of N
    /// backticks opens a span only a later run of exactly N backticks closes
    /// (CommonMark); an unmatched run is ordinary text.
    private static func collectInlineCodeSpans(_ text: Units, _ lineStart: Int, _ lineEnd: Int,
                                               _ spans: inout [Range]) {
        func runEnd(_ from: Int) -> Int {
            var end = from
            while end < lineEnd, text[end] == backtick { end += 1 }
            return end
        }

        var index = lineStart
        while index < lineEnd {
            guard text[index] == backtick else {
                index += 1
                continue
            }
            let openEnd = runEnd(index)
            let width = openEnd - index

            var closeEnd: Int?
            var scan = openEnd
            while scan < lineEnd {
                guard text[scan] == backtick else {
                    scan += 1
                    continue
                }
                let end = runEnd(scan)
                if end - scan == width {
                    closeEnd = end
                    break
                }
                scan = end
            }

            guard let end = closeEnd else {
                index = openEnd
                continue
            }
            spans.append((index, end))
            index = end
        }
    }

    private static func isWithin(_ index: Int, _ ranges: [Range]) -> Bool {
        ranges.contains { index >= $0.start && index < $0.end }
    }

    /// The next `marker` at or after `from` that is not quoted as code.
    private static func indexOutsideCode(_ text: Units, _ marker: Units, from: Int, _ codeSpans: [Range]) -> Int? {
        var at = indexOf(text, marker, from: from)
        while let found = at, isWithin(found, codeSpans) {
            at = indexOf(text, marker, from: found + marker.count)
        }
        return at
    }

    /// Whether the opener at `index` begins its own line, within CommonMark's
    /// three-column indent (past it the line is an indented code block, which
    /// markdown renders literally). A tab advances to the next multiple of four,
    /// so one leading tab is already past the threshold.
    private static func opensOwnLine(_ text: Units, _ index: Int) -> Bool {
        var lineStart = index
        while lineStart > 0, text[lineStart - 1] != newline { lineStart -= 1 }
        let lead = string(text, lineStart, index)
        guard ToolNameNormalizer.jsTrim(lead).isEmpty else { return false }
        let columns = text[lineStart..<index].reduce(0) { $0 + ($1 == tab ? 4 : 1) }
        return columns <= 3
    }

    // MARK: - Code units

    private static let openBytes = Array(openTag.utf8)

    /// `text.includes("<proposed_plan>")` on the native UTF-8 bytes — the same
    /// answer as a code-unit search (the tag is ASCII), and unlike `String`'s
    /// grapheme-aware `contains`, a combining mark after `>` cannot hide it.
    static func containsOpenTag(_ text: String) -> Bool {
        let first = openBytes[0]
        var matched = 0
        var iterator = text.utf8.makeIterator()
        while let byte = iterator.next() {
            if byte == openBytes[matched] {
                matched += 1
                if matched == openBytes.count { return true }
            } else {
                // No byte of the tag repeats its first (`<`), so a mismatch can
                // only restart at this byte.
                matched = byte == first ? 1 : 0
            }
        }
        return false
    }

    private static func string(_ text: Units, _ start: Int, _ end: Int) -> String {
        String(decoding: text[start..<end], as: UTF16.self)
    }

    private static func indexOf(_ text: Units, _ unit: UInt16, from: Int) -> Int? {
        guard from < text.count else { return nil }
        return text[from...].firstIndex(of: unit)
    }

    /// `String.prototype.indexOf` on code units.
    private static func indexOf(_ text: Units, _ needle: Units, from: Int) -> Int? {
        guard !needle.isEmpty, text.count >= needle.count else { return nil }
        var index = max(0, from)
        let last = text.count - needle.count
        while index <= last {
            if text[index] == needle[0] {
                var match = true
                for offset in 1..<needle.count where text[index + offset] != needle[offset] {
                    match = false
                    break
                }
                if match { return index }
            }
            index += 1
        }
        return nil
    }
}
