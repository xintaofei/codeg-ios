import Foundation

/// A mention the user picked from the `@` panel, as the composer keeps it.
///
/// The field shows a readable token (`@docs/README.md`, `@Codex`); the prompt
/// carries the web's wire form — a plain-text Markdown link inside the text
/// block (`[README.md](file:///…/docs/README.md)`, `[@Codex](codeg://agent/codex)`).
/// That link is what the web transcript turns back into a chip, and the agent
/// one is what the backend routes a delegation by, so it is built exactly the
/// way the web's `referenceToMarkdown` builds it.
struct ComposerReference: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case file, agent }

    /// The text the field shows, `@` included. Matched exactly when encoding.
    let token: String
    let kind: Kind
    /// The link text without the agent's `@`: a file's name, an agent's name.
    let label: String
    /// `file://…` or `codeg://agent/<agent_type>`.
    let uri: String

    /// The inline wire form (web `referenceToMarkdown`).
    var markdown: String {
        let text = ComposerReferenceCodec.escapeMarkdownText(ComposerReferenceCodec.collapseNewlines(label))
        let destination = ComposerReferenceCodec.escapeLinkDestination(uri)
        switch kind {
        case .file: return "[\(text)](\(destination))"
        case .agent: return "[@\(text)](\(destination))"
        }
    }

    /// A workspace file or directory (web `fileToSuggestion`): the token is the
    /// root-relative path, the link text the entry's name.
    static func file(name: String, relativePath: String, workspaceRoot: String) -> ComposerReference {
        ComposerReference(
            token: "@" + relativePath,
            kind: .file,
            label: name.isEmpty ? relativePath : name,
            uri: ComposerReferenceCodec.buildFileUri(ComposerReferenceCodec.joinPath(workspaceRoot, relativePath))
        )
    }

    /// An agent (web `agentToSuggestion`): `codeg://agent/<agent_type>` is the
    /// routing anchor the backend derives the delegation reminder from.
    static func agent(_ agentType: AgentType, label: String) -> ComposerReference {
        let name = label.isEmpty ? agentType.rawValue : label
        return ComposerReference(token: "@" + name, kind: .agent, label: name,
                                 uri: "codeg://agent/\(agentType.rawValue)")
    }
}

/// Turns the field's readable mention tokens into the web's Markdown links on
/// the way out, and links back into tokens when a sent message returns to the
/// composer (a rejected send, a queued message taken back for editing).
///
/// The escape and URI builders are exact ports of web `reference-text.ts` and
/// `src/lib/reference-link.ts`, so a mention sent from here renders as a chip
/// in the web transcript. All scanning is in UTF-16 code units, like the web.
enum ComposerReferenceCodec {

    // MARK: - Encode

    /// Replace every registered token in `text` with its Markdown link.
    ///
    /// A token counts only where the user could have inserted it — where a
    /// mention may start (``MentionStart``) — and only when it ends at a
    /// boundary: the end, whitespace, CJK text or closing punctuation, or a
    /// sentence-ending `.`. A token the user edited (`@README.md` → `@README.mdx`)
    /// therefore no longer matches and goes out as the plain text it now is.
    /// Longer tokens are tried first, so `@a b.md` wins over `@a`.
    static func encode(_ text: String, references: [ComposerReference]) -> String {
        guard !references.isEmpty, text.contains("@") else { return text }
        var seen = Set<String>()
        let ordered = references
            .filter { !$0.token.isEmpty && seen.insert($0.token).inserted }
            .map { (ref: $0, units: Array($0.token.utf16)) }
            .sorted { $0.units.count > $1.units.count }
        let units = Array(text.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            if units[i] == 0x40, MentionStart.canStart(units, at: i),
               let hit = ordered.first(where: { matches($0.units, in: units, at: i) }) {
                out.append(contentsOf: hit.ref.markdown.utf16)
                i += hit.units.count
                continue
            }
            out.append(units[i])
            i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }

    private static func matches(_ token: [UInt16], in units: [UInt16], at i: Int) -> Bool {
        let end = i + token.count
        guard end <= units.count, units[i..<end].elementsEqual(token) else { return false }
        return endsToken(units, at: end)
    }

    /// Whether a token ending at `end` stops there rather than running on into
    /// something the user typed after it.
    static func endsToken(_ units: [UInt16], at end: Int) -> Bool {
        guard end < units.count else { return true }
        let next = units[end]
        if JSWhitespace.contains(next) { return true }
        // A sentence-ending period, not a longer file name.
        if next == 0x2E { return end + 1 == units.count || JSWhitespace.contains(units[end + 1]) }
        if closingPunctuation.contains(next) { return true }
        // CJK text runs straight on without a space; the same set that may
        // precede a mention may follow one.
        if UTF16.isLeadSurrogate(next) {
            guard end + 1 < units.count, UTF16.isTrailSurrogate(units[end + 1]) else { return false }
            let value = 0x10000 + ((UInt32(next) - 0xD800) << 10) + (UInt32(units[end + 1]) - 0xDC00)
            return Unicode.Scalar(value).map(MentionStart.isAllowedPrefix) ?? false
        }
        guard next > 0x7F, let scalar = Unicode.Scalar(next) else { return false }
        return MentionStart.isAllowedPrefix(scalar)
    }

    private static let closingPunctuation: Set<UInt16> = Set(",;:!?)]}>\"'".utf16)

    // MARK: - Decode

    /// Turn the links a sent message carries back into tokens, returning the
    /// text the field should show and the references to register for it.
    ///
    /// Only what the composer itself produces is folded: a `file://` link to a
    /// path under `workspaceRoot`, and a `codeg://agent/…` link. Anything else
    /// — and any link whose token would not survive the next ``encode(_:references:)``
    /// at that spot, e.g. one glued to the word before it — stays as written,
    /// so restoring and re-sending reproduces the original text.
    static func decode(_ text: String, workspaceRoot: String?) -> (text: String, references: [ComposerReference]) {
        let tokens = tokenizeReferenceLinks(text)
        guard tokens.contains(where: { if case .link = $0 { return true } else { return false } }) else {
            return (text, [])
        }
        var out: [UInt16] = []
        var references: [ComposerReference] = []
        for (index, token) in tokens.enumerated() {
            switch token {
            case .text(let value):
                out.append(contentsOf: value.utf16)
            case .link(let raw, let label, let destination):
                // The character that will follow the token: the next prose run's
                // first one, or the end. A link right after is never a boundary
                // (it opens with `[`, or `@` once folded) — which also holds for a
                // link right after that prose run.
                let followerOK: Bool
                if index + 1 < tokens.count {
                    if case .text(let next) = tokens[index + 1] {
                        var follow = Array(next.utf16)
                        if index + 2 < tokens.count { follow.append(0x5B) }
                        followerOK = endsToken(follow, at: 0)
                    } else {
                        followerOK = false
                    }
                } else {
                    followerOK = true
                }
                if followerOK, MentionStart.canStart(out, at: out.count),
                   let folded = foldedReference(label: unescapeReferenceLabel(label),
                                                destination: unwrapReferenceDestination(destination),
                                                workspaceRoot: workspaceRoot) {
                    out.append(contentsOf: folded.token.utf16)
                    references.append(folded)
                } else {
                    out.append(contentsOf: raw.utf16)
                }
            }
        }
        return (String(decoding: out, as: UTF16.self), references)
    }

    private static func foldedReference(label: String, destination: String, workspaceRoot: String?) -> ComposerReference? {
        let lower = destination.lowercased()
        if lower.hasPrefix("file:") {
            guard let root = workspaceRoot, !root.isEmpty,
                  let relative = relativePath(ofFileURI: destination, under: root) else { return nil }
            return ComposerReference(token: "@" + relative, kind: .file,
                                     label: label.isEmpty ? relative : label, uri: destination)
        }
        if lower.hasPrefix("codeg://agent/") {
            let type = String(destination.dropFirst("codeg://agent/".count))
            guard !type.isEmpty else { return nil }
            // The link text is `@name`; one leading `@` is the mention's own.
            var name = label
            if name.hasPrefix("@") { name.removeFirst() }
            if name.isEmpty { name = type }
            return ComposerReference(token: "@" + name, kind: .agent, label: name, uri: destination)
        }
        return nil
    }

    /// The root-relative path a `file://` URI points at, when it is exactly
    /// what ``buildFileUri(_:)`` makes of `root` joined with that path.
    static func relativePath(ofFileURI uri: String, under root: String) -> String? {
        let base = buildFileUri(joinPath(root, ""))
        let baseWithSlash = base.hasSuffix("/") ? base : base + "/"
        guard uri.hasPrefix(baseWithSlash) else { return nil }
        let rest = String(uri.dropFirst(baseWithSlash.count))
        guard !rest.isEmpty else { return nil }
        var segments: [String] = []
        for segment in rest.split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(segment).removingPercentEncoding else { return nil }
            segments.append(decoded)
        }
        let relative = segments.joined(separator: "/")
        // Only a URI the builder would produce again folds; anything else (a
        // fragment, odd encoding) keeps its link.
        guard buildFileUri(joinPath(root, relative)) == uri else { return nil }
        return relative
    }

    // MARK: - Display

    /// Every reference link folded to its label (web `foldReferenceLinks`), for
    /// one-line text such as a new conversation's title seed.
    static func foldLinks(_ text: String) -> String {
        var out = ""
        for token in tokenizeReferenceLinks(text) {
            switch token {
            case .text(let value): out += value
            case .link(_, let label, _): out += unescapeReferenceLabel(label)
            }
        }
        return out
    }

    // MARK: - Web reference-text.ts

    /// Collapse each whitespace run holding a line break into one space, so a
    /// reference stays one inline token (`/\s*[\r\n]+\s*/g → " "`).
    static func collapseNewlines(_ text: String) -> String {
        let units = Array(text.utf16)
        guard units.contains(where: { $0 == 0x0A || $0 == 0x0D }) else { return text }
        var out: [UInt16] = []
        var i = 0
        while i < units.count {
            guard JSWhitespace.contains(units[i]) else {
                out.append(units[i])
                i += 1
                continue
            }
            var j = i
            var hasBreak = false
            while j < units.count, JSWhitespace.contains(units[j]) {
                if units[j] == 0x0A || units[j] == 0x0D { hasBreak = true }
                j += 1
            }
            if hasBreak { out.append(0x20) } else { out.append(contentsOf: units[i..<j]) }
            i = j
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// Backslash-escape every inline-significant ASCII punctuation character
    /// (``\ ` * _ ~ [ ] ( ) < >``) so a label cannot inject Markdown structure.
    static func escapeMarkdownText(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if markdownSignificant.contains(scalar) { out.unicodeScalars.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    private static let markdownSignificant: Set<Unicode.Scalar> = Set("\\`*_~[]()<>".unicodeScalars)

    /// A Markdown link destination: wrapped in `<…>` (with `\`, `<`, `>`
    /// escaped inside) when it holds whitespace, parentheses, angle brackets or
    /// a backslash — so a `)` or trailing `\` cannot end the link early.
    /// Line breaks are stripped. Clean URIs stay bare.
    static func escapeLinkDestination(_ uri: String) -> String {
        // Filtered as UTF-16 units, so a CRLF pair (one Swift Character) loses
        // both halves, like the web's `/[\r\n]+/g`.
        let cleaned = String(decoding: uri.utf16.filter { $0 != 0x0D && $0 != 0x0A }, as: UTF16.self)
        let needsWrap = cleaned.utf16.contains { unit in
            JSWhitespace.contains(unit) || unit == 0x28 || unit == 0x29 || unit == 0x3C || unit == 0x3E || unit == 0x5C
        }
        guard needsWrap else { return cleaned }
        var inner = ""
        for scalar in cleaned.unicodeScalars {
            if scalar == "\\" || scalar == "<" || scalar == ">" { inner.unicodeScalars.append("\\") }
            inner.unicodeScalars.append(scalar)
        }
        return "<\(inner)>"
    }

    // MARK: - Web reference-link.ts

    /// Web `joinPath` (adapters.ts): one `/` between root and relative path.
    static func joinPath(_ root: String, _ relative: String) -> String {
        var left = Substring(root)
        while let last = left.last, last == "/" || last == "\\" { left.removeLast() }
        var right = Substring(relative)
        while let first = right.first, first == "/" || first == "\\" { right.removeFirst() }
        return left.isEmpty ? String(right) : "\(left)/\(right)"
    }

    /// A `file://` URI from an absolute path (POSIX or Windows), each segment
    /// percent-encoded like `encodeURIComponent`: `/a/b` → `file:///a/b`, a
    /// drive path → `file:///C%3A/…`, a UNC path → `file://server/share/…`.
    static func buildFileUri(_ absolutePath: String) -> String {
        let normalized = stripVerbatimPrefix(absolutePath.replacingOccurrences(of: "\\", with: "/"))
        if normalized.hasPrefix("//") {
            return "file://" + encodeSegments(String(normalized.dropFirst(2)))
        }
        let encoded = encodeSegments(normalized)
        return normalized.hasPrefix("/") ? "file://\(encoded)" : "file:///\(encoded)"
    }

    private static func encodeSegments(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encodeURIComponent(String($0)) }
            .joined(separator: "/")
    }

    /// Drop a Windows verbatim prefix (`//?/C:/…`, `//?/UNC/srv/share/…`) from
    /// an already slash-normalized path; device paths are left alone.
    private static func stripVerbatimPrefix(_ normalized: String) -> String {
        let uncPrefix = "//?/UNC/"
        if normalized.utf16.count >= uncPrefix.utf16.count,
           String(normalized.prefix(uncPrefix.count)).uppercased() == uncPrefix {
            return "//" + normalized.dropFirst(uncPrefix.count)
        }
        if normalized.hasPrefix("//?/") {
            let rest = normalized.dropFirst(4)
            let chars = Array(rest.prefix(2))
            if chars.count == 2, chars[1] == ":", chars[0].isASCII, chars[0].isLetter {
                return String(rest)
            }
        }
        return normalized
    }

    /// JS `encodeURIComponent`: everything but `A–Z a–z 0–9 - _ . ! ~ * ' ( )`
    /// becomes `%XX` over its UTF-8 bytes.
    static func encodeURIComponent(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if uriUnreserved.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out.unicodeScalars.append("%")
                out.unicodeScalars.append(hexDigits[Int(byte >> 4)])
                out.unicodeScalars.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return out
    }

    private static let hexDigits: [Unicode.Scalar] = Array("0123456789ABCDEF".unicodeScalars)

    private static let uriUnreserved: Set<UInt8> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)

    /// Reverse ``escapeMarkdownText(_:)``.
    static func unescapeReferenceLabel(_ label: String) -> String {
        unescape(label, set: markdownSignificant)
    }

    /// Reverse ``escapeLinkDestination(_:)``: unwrap `<…>` and drop the
    /// backslashes it escapes `\`, `<` and `>` with. A bare destination is only
    /// trimmed.
    static func unwrapReferenceDestination(_ destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count >= 2 else { return trimmed }
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return unescape(inner, set: ["\\", "<", ">"])
    }

    /// `s.replace(/\\([set])/g, "$1")`.
    private static func unescape(_ text: String, set: Set<Unicode.Scalar>) -> String {
        guard text.contains("\\") else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\\", i + 1 < scalars.count, set.contains(scalars[i + 1]) {
                out.append(scalars[i + 1])
                i += 2
            } else {
                out.append(scalars[i])
                i += 1
            }
        }
        return String(out)
    }

    /// One prose run or one parsed `[label](destination)` link.
    enum LinkToken: Equatable {
        case text(String)
        /// `label` is still escaped; `destination` is as written, `<…>` included.
        case link(raw: String, label: String, destination: String)
    }

    /// Web `tokenizeReferenceLinks`: a single forward scan over a stack of
    /// unmatched `[`. A `]` closes the most recent `[`; followed by a
    /// well-formed `(dest)` with a non-empty label it is a link. Escaped
    /// brackets never open or close. Every input unit lands in one token.
    static func tokenizeReferenceLinks(_ text: String) -> [LinkToken] {
        let s = Array(text.utf16)
        let n = s.count
        var tokens: [LinkToken] = []
        var textStart = 0
        var openers: [Int] = []
        var i = 0

        func slice(_ a: Int, _ b: Int) -> String { String(decoding: s[a..<b], as: UTF16.self) }
        func flushText(before end: Int) {
            if end > textStart { tokens.append(.text(slice(textStart, end))) }
        }

        while i < n {
            if escapesNext(s, i) {
                i += 2
                continue
            }
            let c = s[i]
            if c == 0x5B { // [
                openers.append(i)
                i += 1
                continue
            }
            if c == 0x5D, let open = openers.popLast() { // ]
                let end = destinationEnd(s, i + 1)
                if end != -1, i > open + 1 {
                    flushText(before: open)
                    tokens.append(.link(raw: slice(open, end), label: slice(open + 1, i),
                                        destination: slice(i + 2, end - 1)))
                    openers.removeAll()
                    i = end
                    textStart = end
                    continue
                }
                i += 1
                continue
            }
            i += 1
        }
        flushText(before: n)
        return tokens
    }

    /// A backslash escapes the next unit only when that unit is not whitespace.
    private static func escapesNext(_ s: [UInt16], _ k: Int) -> Bool {
        s[k] == 0x5C && k + 1 < s.count && !JSWhitespace.contains(s[k + 1])
    }

    /// Index just past the `)` of a well-formed `(destination)` at `start`, or -1.
    private static func destinationEnd(_ s: [UInt16], _ start: Int) -> Int {
        let n = s.count
        guard start < n, s[start] == 0x28 else { return -1 } // (
        var k = start + 1
        if k < n, s[k] == 0x3C { // <
            k += 1
            while k < n {
                if escapesNext(s, k) {
                    k += 2
                    continue
                }
                let c = s[k]
                if c == 0x3E { return k + 1 < n && s[k + 1] == 0x29 ? k + 2 : -1 } // > then )
                if c == 0x3C || c == 0x0A || c == 0x0D { return -1 }
                k += 1
            }
            return -1
        }
        while k < n {
            if escapesNext(s, k) {
                k += 2
                continue
            }
            let c = s[k]
            if c == 0x29 { return k + 1 }
            if c == 0x28 || c == 0x3C || c == 0x3E || JSWhitespace.contains(c) { return -1 }
            k += 1
        }
        return -1
    }
}
