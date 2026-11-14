import Foundation

/// A Markdown image (`![alt](destination)`) lifted out of a paragraph.
struct MarkdownImageRef: Hashable, Sendable {
    /// The label as plain text (inline markup and escapes resolved).
    let alt: String
    /// The destination as CommonMark reads it: angle brackets dropped,
    /// backslash escapes and entity references resolved — the mdast `url`
    /// the web's `remarkLocalImages` hands to `localImagePath`.
    let source: String
    /// The destination of the link the image sits in (`[![a](b)](href)`), if
    /// any. A linked image opens its link on tap, not the image viewer.
    let link: String?
    /// The source had a backslash escape somewhere from its destination on.
    /// Such a destination may have lost a Windows separator to it
    /// (`shots\.preview.png` reads as `shots.preview.png`, a different file
    /// that may well exist), so it is never resolved as a local file — the
    /// web's `separatorMayBeLost`.
    let escapeInDestination: Bool

    var linked: Bool { link != nil }
}

/// Splits a paragraph's source at its images, so each image renders as a
/// block of its own (`MarkdownContent` draws everything else through Apple's
/// inline-only parser, which keeps an image as nothing but its alt text).
///
/// A cheap scanner, not a CommonMark inline parser: it knows just enough to
/// find images where the web's would — skipping code spans and backslash
/// escapes, recognising an image wrapped in a link, and leaving a link with
/// other text alone. An image counts only once its closing `)` is there, so a
/// streaming `![shot](./sh` stays text until the destination completes.
enum MarkdownInlineImages {
    enum Segment: Equatable {
        case text(String)
        case image(MarkdownImageRef)
    }

    /// The paragraph cut at its images, or nil when it has none (the common
    /// case, decided by a substring test before any scanning).
    static func split(_ text: String) -> [Segment]? {
        guard text.contains("![") else { return nil }
        let b = Array(text.utf8)
        var segments: [Segment] = []
        var textStart = 0
        var found = false
        var i = 0

        func flushText(upTo end: Int) {
            if end > textStart {
                segments.append(.text(String(decoding: b[textStart..<end], as: UTF8.self)))
            }
        }

        while i < b.count {
            switch b[i] {
            case backslash:
                i += (i + 1 < b.count && isASCIIPunctuation(b[i + 1])) ? 2 : 1
            case backtick:
                i = skipCodeSpan(b, from: i)
            case openBracket:
                guard let link = parseLink(b, at: i) else { i += 1; continue }
                if let image = soleImage(b, in: link.text, link: link.destination) {
                    flushText(upTo: i)
                    segments.append(.image(image))
                    textStart = link.end
                    found = true
                }
                // A link with anything else in it stays one piece of text: an
                // image inside it keeps its alt text, the link keeps working.
                i = link.end
            case bang:
                guard i + 1 < b.count, b[i + 1] == openBracket,
                      let parsed = parseImage(b, at: i) else { i += 1; continue }
                flushText(upTo: i)
                segments.append(.image(parsed.image))
                i = parsed.end
                textStart = i
                found = true
            default:
                i += 1
            }
        }
        guard found else { return nil }
        flushText(upTo: b.count)
        return segments
    }

    // MARK: - Pieces

    private struct ParsedLink {
        let text: Range<Int>
        let destination: String
        let end: Int
    }

    /// `[text](destination "title")` starting at `start`.
    private static func parseLink(_ b: [UInt8], at start: Int) -> ParsedLink? {
        guard let close = labelEnd(b, from: start + 1),
              close + 1 < b.count, b[close + 1] == openParen,
              let resource = parseResource(b, from: close + 2) else { return nil }
        return ParsedLink(text: (start + 1)..<close,
                          destination: unescape(resource.destination(in: b)),
                          end: resource.end)
    }

    /// `![label](destination "title")` starting at `start` (the `!`).
    private static func parseImage(_ b: [UInt8], at start: Int) -> (image: MarkdownImageRef, end: Int)? {
        guard let close = labelEnd(b, from: start + 2),
              close + 1 < b.count, b[close + 1] == openParen,
              let resource = parseResource(b, from: close + 2) else { return nil }
        let label = String(decoding: b[(start + 2)..<close], as: UTF8.self)
        let image = MarkdownImageRef(
            alt: plainText(label),
            source: unescape(resource.destination(in: b)),
            link: nil,
            escapeInDestination: escapeAfterDestinationStart(b[start..<resource.end])
        )
        return (image, resource.end)
    }

    /// The link text is one image and nothing else — give or take surrounding
    /// whitespace and emphasis markers (`[**![a](b)**](href)`).
    private static func soleImage(_ b: [UInt8], in text: Range<Int>, link: String) -> MarkdownImageRef? {
        var lo = text.lowerBound
        var hi = text.upperBound
        while lo < hi, isWhitespace(b[lo]) || b[lo] == star || b[lo] == underscore { lo += 1 }
        while hi > lo, isWhitespace(b[hi - 1]) || b[hi - 1] == star || b[hi - 1] == underscore { hi -= 1 }
        guard hi - lo > 2, b[lo] == bang, b[lo + 1] == openBracket else { return nil }
        let inner = Array(b[lo..<hi])
        guard let parsed = parseImage(inner, at: 0), parsed.end == inner.count else { return nil }
        let image = parsed.image
        return MarkdownImageRef(alt: image.alt, source: image.source, link: link,
                                escapeInDestination: image.escapeInDestination)
    }

    /// The `]` closing a label that opens at `from`: brackets nest, escapes
    /// and code spans are skipped.
    private static func labelEnd(_ b: [UInt8], from: Int) -> Int? {
        var depth = 0
        var j = from
        while j < b.count {
            switch b[j] {
            case backslash:
                j += (j + 1 < b.count && isASCIIPunctuation(b[j + 1])) ? 2 : 1
                continue
            case backtick:
                j = skipCodeSpan(b, from: j)
                continue
            case openBracket:
                depth += 1
            case closeBracket:
                if depth == 0 { return j }
                depth -= 1
            default:
                break
            }
            j += 1
        }
        return nil
    }

    private struct Resource {
        let range: Range<Int>
        let end: Int
        func destination(in b: [UInt8]) -> String {
            String(decoding: b[range], as: UTF8.self)
        }
    }

    /// `(destination "title")` after its `(`: a `<…>` or bare destination
    /// (balanced parentheses, no spaces), an optional title, then `)`.
    private static func parseResource(_ b: [UInt8], from start: Int) -> Resource? {
        var j = skipWhitespace(b, from: start)
        guard j < b.count else { return nil }
        let destination: Range<Int>
        if b[j] == lessThan {
            var k = j + 1
            while k < b.count {
                if b[k] == backslash, k + 1 < b.count, isASCIIPunctuation(b[k + 1]) { k += 2; continue }
                if b[k] == greaterThan { break }
                if b[k] == newline || b[k] == lessThan { return nil }
                k += 1
            }
            guard k < b.count else { return nil }
            destination = (j + 1)..<k
            j = k + 1
        } else {
            var depth = 0
            var k = j
            while k < b.count {
                let c = b[k]
                if c == backslash, k + 1 < b.count, isASCIIPunctuation(b[k + 1]) { k += 2; continue }
                if c == openParen {
                    depth += 1
                } else if c == closeParen {
                    if depth == 0 { break }
                    depth -= 1
                } else if c <= 0x20 || c == 0x7F {
                    break
                }
                k += 1
            }
            guard depth == 0 else { return nil }
            destination = j..<k
            j = k
        }

        let afterDestination = j
        j = skipWhitespace(b, from: j)
        if j < b.count, j > afterDestination,
           b[j] == doubleQuote || b[j] == singleQuote || b[j] == openParen {
            let closer = b[j] == openParen ? closeParen : b[j]
            var k = j + 1
            while k < b.count {
                if b[k] == backslash, k + 1 < b.count, isASCIIPunctuation(b[k + 1]) { k += 2; continue }
                if b[k] == closer { break }
                k += 1
            }
            guard k < b.count else { return nil }
            j = skipWhitespace(b, from: k + 1)
        }
        guard j < b.count, b[j] == closeParen else { return nil }
        return Resource(range: destination, end: j + 1)
    }

    /// Past a code span that opens at `from` (a run of backticks closed by a
    /// run of the same length), or past the run alone when nothing closes it.
    private static func skipCodeSpan(_ b: [UInt8], from: Int) -> Int {
        var j = from
        while j < b.count, b[j] == backtick { j += 1 }
        let run = j - from
        var k = j
        while k < b.count {
            if b[k] != backtick { k += 1; continue }
            var m = k
            while m < b.count, b[m] == backtick { m += 1 }
            if m - k == run { return m }
            k = m
        }
        return j
    }

    /// Spaces and tabs, and at most one line ending.
    private static func skipWhitespace(_ b: [UInt8], from: Int) -> Int {
        var j = from
        var sawNewline = false
        while j < b.count {
            if b[j] == space || b[j] == tab { j += 1; continue }
            if b[j] == newline, !sawNewline { sawNewline = true; j += 1; continue }
            if b[j] == carriageReturn, !sawNewline {
                sawNewline = true
                j += 1
                if j < b.count, b[j] == newline { j += 1 }
                continue
            }
            break
        }
        return j
    }

    /// `separatorMayBeLost`: a `\` + ASCII punctuation anywhere from the first
    /// place a destination can start (past the first `](`) to the end of the
    /// image. The label before that point is ignored, so `![a \* b](./x.png)`
    /// still resolves; an escape in the title over-refuses, as on the web.
    static func escapeAfterDestinationStart(_ raw: ArraySlice<UInt8>) -> Bool {
        var start = raw.startIndex
        var k = raw.startIndex
        while k + 1 < raw.endIndex {
            if raw[k] == closeBracket, raw[k + 1] == openParen || raw[k + 1] == colon {
                start = k + 2
                break
            }
            k += 1
        }
        var j = start
        while j + 1 < raw.endIndex {
            if raw[j] == backslash, isASCIIPunctuation(raw[j + 1]) { return true }
            j += 1
        }
        return false
    }

    /// Backslash escapes and entity references resolved, as CommonMark does to
    /// a destination.
    static func unescape(_ s: String) -> String {
        guard s.contains("\\") || s.contains("&") else { return s }
        var out = ""
        var scalars = s.unicodeScalars[...]
        while let u = scalars.first {
            if u == "\\", let next = scalars.dropFirst().first,
               next.isASCII, isASCIIPunctuation(UInt8(next.value)) {
                out.unicodeScalars.append(next)
                scalars = scalars.dropFirst(2)
                continue
            }
            if u == "&", let reference = entity(scalars) {
                out.unicodeScalars.append(contentsOf: reference.text.unicodeScalars)
                scalars = scalars.dropFirst(reference.length)
                continue
            }
            out.unicodeScalars.append(u)
            scalars = scalars.dropFirst()
        }
        return out
    }

    /// The common named references and every numeric one, from `&` on.
    private static func entity(_ s: Substring.UnicodeScalarView) -> (text: String, length: Int)? {
        let head = String(String.UnicodeScalarView(s.prefix(12)))
        guard let semicolon = head.firstIndex(of: ";") else { return nil }
        let body = head[head.index(after: head.startIndex)..<semicolon]
        let length = body.unicodeScalars.count + 2
        switch body {
        case "amp": return ("&", length)
        case "lt": return ("<", length)
        case "gt": return (">", length)
        case "quot": return ("\"", length)
        case "apos": return ("'", length)
        case "nbsp": return ("\u{00A0}", length)
        default: break
        }
        guard body.hasPrefix("#") else { return nil }
        let digits = body.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value, value != 0, let scalar = Unicode.Scalar(value) else {
            return value == 0 ? ("\u{FFFD}", length) : nil
        }
        return (String(Character(scalar)), length)
    }

    /// The label as the plain text an `alt` attribute gets: inline markup and
    /// escapes resolved.
    static func plainText(_ label: String) -> String {
        guard label.contains(where: { "\\*_`[]&<".contains($0) }) else { return label }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: label, options: options) else { return label }
        return String(parsed.characters)
    }

    // MARK: - Bytes

    private static let backslash = UInt8(ascii: "\\")
    private static let backtick = UInt8(ascii: "`")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")
    private static let openParen = UInt8(ascii: "(")
    private static let closeParen = UInt8(ascii: ")")
    private static let bang = UInt8(ascii: "!")
    private static let lessThan = UInt8(ascii: "<")
    private static let greaterThan = UInt8(ascii: ">")
    private static let doubleQuote = UInt8(ascii: "\"")
    private static let singleQuote = UInt8(ascii: "'")
    private static let star = UInt8(ascii: "*")
    private static let underscore = UInt8(ascii: "_")
    private static let colon = UInt8(ascii: ":")
    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")
    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    private static func isWhitespace(_ c: UInt8) -> Bool {
        c == space || c == tab || c == newline || c == carriageReturn
    }

    /// CommonMark's ASCII punctuation: what a backslash can escape.
    static func isASCIIPunctuation(_ c: UInt8) -> Bool {
        (0x21...0x2F).contains(c) || (0x3A...0x40).contains(c)
            || (0x5B...0x60).contains(c) || (0x7B...0x7E).contains(c)
    }
}
