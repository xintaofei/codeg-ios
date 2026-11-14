import Foundation

/// The chat HTML preview's document, built from a ```` ```html ```` fence the
/// way the web's `buildChatHtmlDocument` builds it (`chat-html-document.ts`,
/// `html-preview-inline.ts`):
///
/// 1. **Strip active content** (`inlineHtmlResources` with
///    `stripActiveContent`): `script`, `iframe`, `object`, `embed`, `link` and
///    `template` elements go, with their content; so do SVG `set`/`animate`
///    that write a link target, author CSP and refresh `<meta>`, and `<base>`.
///    On every element left, `on*` handlers, `href`/`xlink:href` other than a
///    `#fragment` into the document, `action`, `formaction`, `nonce` and
///    `srcdoc` go. No resource is inlined (the chat reads no local files).
/// 2. **Normalize** to `<!DOCTYPE html><html><head>…</head><body>…</body>
///    </html>`, split at the source's real `<body>` (else after the leading
///    metadata), keeping the wrappers' attributes — minus active ones.
/// 3. **Theme** — color scheme, base font, the theme's CSS variables — first in
///    `<head>`, ahead of the author's CSS.
/// 4. **Sandbox**: the strict CSP and a pinned `<base>` before everything.
///
/// Unlike the web, the document carries no script at all: this client runs
/// none in it (no nonce, no size reporter — the height is measured by the app),
/// and adds a viewport so WebKit lays it out at the column's width.
///
/// The web parses with a `<template>`; this works on the HTML tokenizer's
/// rules (`HtmlTokenizer`): comments, quoted attributes and raw-text elements
/// are honoured, so markup-looking text inside them is never taken for tags.
/// What it keeps, it keeps byte for byte. The preview also renders with
/// content JavaScript off and every network load blocked, so this pass is
/// defence in depth, not the only line.
enum ChatHtmlDocument {
    /// The web's `CSP_STRICT`, verbatim.
    static let strictCSP = [
        "default-src 'none'",
        "img-src data: blob:",
        "media-src data: blob:",
        "style-src 'unsafe-inline' data:",
        "font-src data:",
        "script-src 'none'",
        "form-action 'none'",
        "base-uri about:",
        "frame-src 'none'",
    ].joined(separator: "; ")

    /// The web's `SANDBOX_BASE`: in-page `#fragment` links resolve against the
    /// document itself, never an external origin.
    static let sandboxBase = #"<base href="about:srcdoc">"#

    /// Lays the document out at the view's width (the web's iframe has its
    /// own); the last viewport in the document wins, so it goes last in head.
    static let viewportMeta = #"<meta name="viewport" content="width=device-width,initial-scale=1,shrink-to-fit=no">"#

    /// The full preview document for a fence's source.
    static func build(source: String, theme: ChatHtmlTheme) -> String {
        let html = inlineStripped(source, headEnd: viewportMeta)
        let themed = withHtmlPreviewHead(html, themeStyle(theme))
        return withSandboxCsp(themed)
    }

    /// The web's injected `<style>`, plus the theme's surface under the page
    /// (the picture is drawn on it) and no text inflation.
    static func themeStyle(_ theme: ChatHtmlTheme) -> String {
        """
        <style>
        :root{color-scheme:\(theme.dark ? "dark" : "light")}
        html,body{margin:0;background:transparent;color:var(--foreground,\(theme.dark ? "#fafafa" : "#1a1c1f"));font:14px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
        *,*::before,*::after{box-sizing:border-box}
        \(theme.variablesCSS)
        html{background:\(theme.surfaceCSS);-webkit-text-size-adjust:100%}
        </style>
        """
    }

    // MARK: Sandbox

    /// The strict CSP, then the pinned base, as the first things in the real
    /// `<head>` (`withSandboxCsp`): the policy is in force before the base is
    /// read, and the base is the document's only one.
    static func withSandboxCsp(_ html: String) -> String {
        let head = #"<meta http-equiv="Content-Security-Policy" content=""# + strictCSP + #"">"# + sandboxBase
        return withHtmlPreviewHead(html, head)
    }

    /// Insert `head` right after the document's real `<head>` start tag — not
    /// one inside a comment, an attribute or raw text (`withHtmlPreviewHead`).
    /// With no `<head>`, a new one goes after `<html>`, else in front.
    static func withHtmlPreviewHead(_ html: String, _ head: String) -> String {
        let bytes = Array(html.utf8)
        let tokens = HtmlTokenizer.tokenize(bytes)
        if let end = firstRealStartTag("head", in: tokens)?.range.upperBound {
            return splice(bytes, at: end, Array(head.utf8))
        }
        if let end = firstRealStartTag("html", in: tokens)?.range.upperBound {
            return splice(bytes, at: end, Array("<head>\(head)</head>".utf8))
        }
        return "<head>\(head)</head>" + html
    }

    private static func splice(_ bytes: [UInt8], at index: Int, _ insert: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + insert.count)
        out.append(contentsOf: bytes[..<index])
        out.append(contentsOf: insert)
        out.append(contentsOf: bytes[index...])
        return String(decoding: out, as: UTF8.self)
    }

    /// The first `<name>` start tag outside any `<template>` content.
    private static func firstRealStartTag(_ name: String, in tokens: [HtmlTokenizer.Token]) -> HtmlTokenizer.Tag? {
        var templateDepth = 0
        for token in tokens {
            switch token {
            case .startTag(let tag):
                if templateDepth == 0, tag.name == name { return tag }
                if tag.name == "template" { templateDepth += 1 }
            case .endTag(let endName, _):
                if endName == "template", templateDepth > 0 { templateDepth -= 1 }
            default:
                break
            }
        }
        return nil
    }

    // MARK: Strip + normalize

    /// The normalized, stripped document (`inlineHtmlResources(html,
    /// {stripActiveContent: true, maxInlineBytes: 0})`). `headEnd` is appended
    /// inside `<head>`, after the author's head content.
    static func inlineStripped(_ html: String, headEnd: String = "") -> String {
        let bytes = Array(html.utf8)
        let tokens = HtmlTokenizer.tokenize(bytes)
        let wrappers = wrapperAttributes(tokens, bytes: bytes)

        let head: [HtmlTokenizer.Token]
        let body: [HtmlTokenizer.Token]
        if let bodyIndex = firstRealStartTagIndex("body", in: tokens) {
            // Split where the source's own <body> starts, so body-leading
            // <script>/<style>/<meta> stay in the body.
            head = sanitize(tokens[..<bodyIndex], bytes: bytes)
            body = sanitize(tokens[(bodyIndex + 1)...], bytes: bytes)
        } else {
            // No <body>: the leading metadata, comments and blank text are the
            // head; everything from the first other node on is the body.
            let all = sanitize(tokens[...], bytes: bytes)
            let split = headSplit(all, bytes: bytes)
            head = Array(all[..<split])
            body = Array(all[split...])
        }
        return "<!DOCTYPE html>\n<html\(wrappers.html)>\n<head\(wrappers.head)>"
            + serialize(head, bytes: bytes) + headEnd
            + "</head>\n<body\(wrappers.body)>" + serialize(body, bytes: bytes)
            + "</body>\n</html>"
    }

    private static func firstRealStartTagIndex(_ name: String, in tokens: [HtmlTokenizer.Token]) -> Int? {
        var templateDepth = 0
        for (index, token) in tokens.enumerated() {
            switch token {
            case .startTag(let tag):
                if templateDepth == 0, tag.name == name { return index }
                if tag.name == "template" { templateDepth += 1 }
            case .endTag(let endName, _):
                if endName == "template", templateDepth > 0 { templateDepth -= 1 }
            default:
                break
            }
        }
        return nil
    }

    /// Attribute text of the first real `<html>`, `<head>` and `<body>` start
    /// tags (`extractWrapperAttrs`), active attributes removed, each as
    /// ` name=value` the way it was written.
    private static func wrapperAttributes(_ tokens: [HtmlTokenizer.Token],
                                          bytes: [UInt8]) -> (html: String, head: String, body: String) {
        var found: [String: HtmlTokenizer.Tag] = [:]
        var templateDepth = 0
        for token in tokens {
            switch token {
            case .startTag(let tag):
                if templateDepth == 0, ["html", "head", "body"].contains(tag.name), found[tag.name] == nil {
                    found[tag.name] = tag
                }
                if tag.name == "template" { templateDepth += 1 }
            case .endTag(let endName, _):
                if endName == "template", templateDepth > 0 { templateDepth -= 1 }
            default:
                break
            }
            if found["body"] != nil { break }
        }
        func text(_ name: String) -> String {
            guard let tag = found[name] else { return "" }
            return tag.attributes.filter { keeps($0, bytes: bytes) }
                .map { " " + string(bytes[$0.range]) }
                .joined()
        }
        return (text("html"), text("head"), text("body"))
    }

    // MARK: Sanitizing

    /// Removed with their content.
    static let removedElements: Set<String> = ["script", "iframe", "object", "embed", "link", "template"]

    /// The HTML parser keeps these in `<head>` (`METADATA_TAGS`).
    private static let metadataElements: Set<String> = [
        "base", "basefont", "bgsound", "link", "meta", "noscript", "script", "style", "template", "title",
    ]

    private static let voidElements: Set<String> = [
        "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input",
        "keygen", "link", "meta", "param", "source", "track", "wbr",
    ]

    /// `html`/`head`/`body` tags inside the source: the web's template parse
    /// drops them, and the normalized document has its own.
    private static func isWrapper(_ name: String) -> Bool {
        name == "html" || name == "head" || name == "body"
    }

    private static func sanitize(_ tokens: ArraySlice<HtmlTokenizer.Token>, bytes: [UInt8]) -> [HtmlTokenizer.Token] {
        var out: [HtmlTokenizer.Token] = []
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let token = tokens[index]
            switch token {
            case .startTag(var tag):
                if isWrapper(tag.name) {
                    index += 1
                    continue
                }
                if removes(tag, bytes: bytes) {
                    index = elementEnd(tokens, from: index, tag: tag, removing: true)
                    continue
                }
                tag.attributes = tag.attributes.filter { keeps($0, bytes: bytes) }
                out.append(.startTag(tag))
            case .endTag(let name, _):
                if !isWrapper(name) { out.append(token) }
            case .doctype:
                break
            case .text, .comment, .rawText:
                out.append(token)
            }
            index += 1
        }
        return out
    }

    /// Whether the element this tag starts is removed.
    private static func removes(_ tag: HtmlTokenizer.Tag, bytes: [UInt8]) -> Bool {
        if removedElements.contains(tag.name) || tag.name == "base" { return true }
        switch tag.name {
        case "set", "animate":
            // SVG animation can set a link target the attribute pass never sees.
            return isLinkTarget(value(of: "attributename", in: tag, bytes: bytes) ?? "")
        case "meta":
            // An author CSP could tighten or confuse ours; a refresh redirects.
            guard let kind = value(of: "http-equiv", in: tag, bytes: bytes) else { return false }
            let normalized = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "content-security-policy" || normalized == "refresh"
        default:
            return false
        }
    }

    /// Whether an attribute survives (`stripActiveAttributes`).
    private static func keeps(_ attribute: HtmlTokenizer.Attribute, bytes: [UInt8]) -> Bool {
        let name = attribute.name
        if name.hasPrefix("on") { return false }
        if ["action", "formaction", "nonce", "srcdoc"].contains(name) { return false }
        if isLinkTarget(name) {
            // A link into the document itself (`#id`: an SVG <use>, a
            // gradient, an in-page anchor) stays; any other would navigate.
            let target = attribute.valueRange.map { HtmlEntities.decode(string(bytes[$0])) } ?? ""
            return target.drop(while: { $0.isWhitespace }).hasPrefix("#")
        }
        return true
    }

    /// `href` under any name — `href`, `xlink:href` (`/(?:^|:)href$/i`).
    static func isLinkTarget(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "href" || lower.hasSuffix(":href")
    }

    /// The decoded value of the tag's first `name` attribute.
    private static func value(of name: String, in tag: HtmlTokenizer.Tag, bytes: [UInt8]) -> String? {
        guard let attribute = tag.attributes.first(where: { $0.name == name }) else { return nil }
        return attribute.valueRange.map { HtmlEntities.decode(string(bytes[$0])) } ?? ""
    }

    /// The index just past the element `tag` (at `from`) starts: itself for a
    /// void or self-closed one, its raw text and end tag for a raw-text one,
    /// else up to its matching end tag (or the end).
    private static func elementEnd(_ tokens: ArraySlice<HtmlTokenizer.Token>, from start: Int,
                                   tag: HtmlTokenizer.Tag, removing: Bool) -> Int {
        let end = tokens.endIndex
        if voidElements.contains(tag.name) { return start + 1 }
        if HtmlTokenizer.rawTextElements.contains(tag.name) {
            var next = start + 1
            if next < end, case .rawText = tokens[next] { next += 1 }
            if next < end, case .endTag(let name, _) = tokens[next], name == tag.name { next += 1 }
            return next
        }
        // SVG's self-closed animation elements; an HTML element ignores the
        // slash, so a removed one takes its content with it.
        let isSVGAnimation = tag.name == "set" || tag.name == "animate"
        if tag.selfClosing, isSVGAnimation || !removing { return start + 1 }
        var depth = 1
        var index = start + 1
        while index < end {
            switch tokens[index] {
            case .startTag(let inner) where inner.name == tag.name:
                if !(inner.selfClosing && isSVGAnimation) { depth += 1 }
            case .endTag(let name, _) where name == tag.name:
                depth -= 1
                if depth == 0 { return index + 1 }
            default:
                break
            }
            index += 1
        }
        return end
    }

    /// Where the head ends in a source without `<body>`.
    private static func headSplit(_ tokens: [HtmlTokenizer.Token], bytes: [UInt8]) -> Int {
        var index = 0
        while index < tokens.count {
            switch tokens[index] {
            case .comment, .endTag:
                // A stray end tag makes no node of its own.
                index += 1
            case .text(let range):
                guard string(bytes[range]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return index
                }
                index += 1
            case .startTag(let tag) where metadataElements.contains(tag.name):
                index = elementEnd(tokens[...], from: index, tag: tag, removing: false)
            default:
                return index
            }
        }
        return index
    }

    // MARK: Serializing

    private static func serialize(_ tokens: [HtmlTokenizer.Token], bytes: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        for token in tokens {
            switch token {
            case .text(let range), .comment(let range), .doctype(let range), .rawText(let range):
                out.append(contentsOf: bytes[range])
            case .endTag(_, let range):
                out.append(contentsOf: bytes[range])
            case .startTag(let tag):
                out.append(0x3C)
                out.append(contentsOf: bytes[tag.nameRange])
                for attribute in tag.attributes {
                    out.append(0x20)
                    out.append(contentsOf: bytes[attribute.range])
                }
                // Spaced, so an unquoted last value doesn't swallow the slash.
                if tag.selfClosing { out.append(contentsOf: [0x20, 0x2F]) }
                out.append(0x3E)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Tokenizer

/// Start tags (with their attributes), end tags, comments, doctypes, text and
/// raw text, on the HTML tokenizer's rules: attribute quoting, `<!-->`-style
/// comment ends, `--!>`, bogus comments (`<!x>`, `<?x>`, `</ x>`), and the raw
/// text of `script`/`style`/`title`/`textarea`/`xmp`/`iframe`/`noembed`/
/// `noframes` (to their own end tag) and `plaintext` (to the end). A tag the
/// input ends inside is dropped, as the tokenizer drops it. Byte offsets are
/// into the source's UTF-8; every markup character is ASCII, so each range
/// cuts the text at character boundaries.
///
/// Not a tree builder: foreign content (SVG/MathML) switches nothing here.
enum HtmlTokenizer {
    struct Attribute {
        /// ASCII-lowercased.
        let name: String
        /// The value as written, without its quotes; nil when there is none.
        let valueRange: Range<Int>?
        /// The attribute as written, name through value.
        let range: Range<Int>
    }

    struct Tag {
        /// ASCII-lowercased.
        let name: String
        let nameRange: Range<Int>
        var attributes: [Attribute]
        let selfClosing: Bool
        /// `<` through `>`.
        let range: Range<Int>
    }

    enum Token {
        case text(Range<Int>)
        case comment(Range<Int>)
        case doctype(Range<Int>)
        case startTag(Tag)
        case endTag(name: String, range: Range<Int>)
        case rawText(Range<Int>)
    }

    static let rawTextElements: Set<String> = [
        "script", "style", "title", "textarea", "xmp", "iframe", "noembed", "noframes",
    ]

    private static let lt: UInt8 = 0x3C, gt: UInt8 = 0x3E, slash: UInt8 = 0x2F
    private static let bang: UInt8 = 0x21, question: UInt8 = 0x3F, dash: UInt8 = 0x2D
    private static let equals: UInt8 = 0x3D, doubleQuote: UInt8 = 0x22, singleQuote: UInt8 = 0x27

    static func tokenize(_ s: [UInt8]) -> [Token] {
        var tokens: [Token] = []
        let n = s.count
        var i = 0
        var textStart = 0
        func flushText(upTo end: Int) {
            if end > textStart { tokens.append(.text(textStart..<end)) }
        }

        scan: while i < n {
            guard let open = index(of: lt, in: s, from: i) else { break }
            let next: UInt8? = open + 1 < n ? s[open + 1] : nil

            if next == bang, hasPrefix(s, at: open, "<!--") {
                flushText(upTo: open)
                let end = commentEnd(s, from: open)
                tokens.append(.comment(open..<end))
                i = end
                textStart = end
                continue
            }
            if next == bang || next == question {
                flushText(upTo: open)
                let end = index(of: gt, in: s, from: open + 2).map { $0 + 1 } ?? n
                if next == bang, hasPrefixIgnoringCase(s, at: open + 2, "doctype") {
                    tokens.append(.doctype(open..<end))
                } else {
                    tokens.append(.comment(open..<end))
                }
                i = end
                textStart = end
                continue
            }
            if next == slash {
                let after = open + 2
                guard after < n else { break scan }      // "</" at the end is text
                if isAlpha(s[after]) {
                    flushText(upTo: open)
                    let (name, nameEnd) = readName(s, from: after)
                    guard let parsed = readAttributes(s, from: nameEnd) else {
                        textStart = n
                        break scan
                    }
                    tokens.append(.endTag(name: name, range: open..<parsed.end))
                    i = parsed.end
                    textStart = parsed.end
                    continue
                }
                flushText(upTo: open)
                if s[after] == gt {                         // "</>" is nothing
                    i = after + 1
                    textStart = i
                    continue
                }
                let end = index(of: gt, in: s, from: after).map { $0 + 1 } ?? n
                tokens.append(.comment(open..<end))
                i = end
                textStart = end
                continue
            }
            if let next, isAlpha(next) {
                let (name, nameEnd) = readName(s, from: open + 1)
                guard let parsed = readAttributes(s, from: nameEnd) else {
                    flushText(upTo: open)
                    textStart = n
                    break scan
                }
                let tagEnd = parsed.end
                flushText(upTo: open)
                tokens.append(.startTag(Tag(name: name, nameRange: (open + 1)..<nameEnd,
                                            attributes: parsed.attributes, selfClosing: parsed.selfClosing,
                                            range: open..<tagEnd)))
                i = tagEnd
                textStart = tagEnd
                if name == "plaintext" {
                    if tagEnd < n { tokens.append(.rawText(tagEnd..<n)) }
                    textStart = n
                    break scan
                }
                if rawTextElements.contains(name) {
                    let close = rawTextEnd(s, name: name, from: tagEnd) ?? n
                    if close > tagEnd { tokens.append(.rawText(tagEnd..<close)) }
                    i = close
                    textStart = close
                }
                continue
            }
            // A "<" that starts nothing is text.
            i = open + 1
        }
        flushText(upTo: n)
        return tokens
    }

    /// The tag name from `start`: up to whitespace, `/` or `>`; lowercased.
    private static func readName(_ s: [UInt8], from start: Int) -> (String, Int) {
        var i = start
        while i < s.count, !isSpace(s[i]), s[i] != slash, s[i] != gt { i += 1 }
        return (lowercased(s[start..<i]), i)
    }

    private struct ParsedAttributes {
        let attributes: [Attribute]
        let selfClosing: Bool
        /// Just past the tag's `>`.
        let end: Int
    }

    /// The attributes from `start` to the tag's `>`: nil when the input ends
    /// first (the tokenizer drops such a tag).
    private static func readAttributes(_ s: [UInt8], from start: Int) -> ParsedAttributes? {
        var attributes: [Attribute] = []
        let n = s.count
        var i = start
        while true {
            while i < n, isSpace(s[i]) { i += 1 }
            guard i < n else { return nil }
            if s[i] == gt { return ParsedAttributes(attributes: attributes, selfClosing: false, end: i + 1) }
            if s[i] == slash {
                i += 1
                if i < n, s[i] == gt { return ParsedAttributes(attributes: attributes, selfClosing: true, end: i + 1) }
                continue
            }
            let nameStart = i
            // The first character always belongs to the name, even "=".
            i += 1
            while i < n, !isSpace(s[i]), s[i] != slash, s[i] != gt, s[i] != equals { i += 1 }
            let nameEnd = i
            var j = i
            while j < n, isSpace(s[j]) { j += 1 }
            var valueRange: Range<Int>?
            var attributeEnd = nameEnd
            if j < n, s[j] == equals {
                j += 1
                while j < n, isSpace(s[j]) { j += 1 }
                guard j < n else { return nil }
                let quote = s[j]
                if quote == doubleQuote || quote == singleQuote {
                    guard let close = index(of: quote, in: s, from: j + 1) else { return nil }
                    valueRange = (j + 1)..<close
                    attributeEnd = close + 1
                } else if quote == gt {
                    valueRange = j..<j
                    attributeEnd = j
                } else {
                    let valueStart = j
                    while j < n, !isSpace(s[j]), s[j] != gt { j += 1 }
                    valueRange = valueStart..<j
                    attributeEnd = j
                }
                i = attributeEnd
            }
            attributes.append(Attribute(name: lowercased(s[nameStart..<nameEnd]), valueRange: valueRange,
                                        range: nameStart..<attributeEnd))
        }
    }

    /// Where a raw-text element's content ends: at `</name` followed by
    /// whitespace, `/` or `>` (`</scriptx>` does not end a script).
    private static func rawTextEnd(_ s: [UInt8], name: String, from start: Int) -> Int? {
        let nameBytes = Array(name.utf8)
        let n = s.count
        var i = start
        while let open = index(of: lt, in: s, from: i) {
            let after = open + 2 + nameBytes.count
            if open + 1 < n, s[open + 1] == slash, after < n,
               hasPrefixIgnoringCase(s, at: open + 2, name),
               isSpace(s[after]) || s[after] == slash || s[after] == gt {
                return open
            }
            i = open + 1
        }
        return nil
    }

    /// The end of the comment that opens at `start` ("<!--"): after `-->`,
    /// `--!>`, or the abrupt `<!-->` / `<!--->`; the input's end otherwise.
    private static func commentEnd(_ s: [UInt8], from start: Int) -> Int {
        let n = s.count
        let body = start + 4
        if body < n, s[body] == gt { return body + 1 }
        if body + 1 < n, s[body] == dash, s[body + 1] == gt { return body + 2 }
        var i = body
        while i + 2 < n {
            if s[i] == dash, s[i + 1] == dash {
                if s[i + 2] == gt { return i + 3 }
                if i + 3 < n, s[i + 2] == bang, s[i + 3] == gt { return i + 4 }
            }
            i += 1
        }
        return n
    }

    private static func index(of byte: UInt8, in s: [UInt8], from start: Int) -> Int? {
        guard start < s.count else { return nil }
        return s[start...].firstIndex(of: byte)
    }

    private static func hasPrefix(_ s: [UInt8], at start: Int, _ prefix: String) -> Bool {
        let p = Array(prefix.utf8)
        guard start + p.count <= s.count else { return false }
        return s[start..<(start + p.count)].elementsEqual(p)
    }

    private static func hasPrefixIgnoringCase(_ s: [UInt8], at start: Int, _ prefix: String) -> Bool {
        let p = Array(prefix.utf8)
        guard start + p.count <= s.count else { return false }
        for k in 0..<p.count where lower(s[start + k]) != lower(p[k]) { return false }
        return true
    }

    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D
    }

    private static func isAlpha(_ b: UInt8) -> Bool {
        (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
    }

    private static func lower(_ b: UInt8) -> UInt8 {
        (0x41...0x5A).contains(b) ? b | 0x20 : b
    }

    private static func lowercased(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map(lower), as: UTF8.self)
    }
}

// MARK: - Entities

/// Character references in an attribute value, decoded far enough to judge
/// what it says: numeric ones and the common named ones. Used only to test a
/// value (a fragment link, a refresh `<meta>`), never to rewrite one.
enum HtmlEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "num": "#", "colon": ":", "sol": "/", "tab": "\t", "newline": "\n", "hyphen": "-", "dash": "-",
        "period": ".", "comma": ",", "lpar": "(", "rpar": ")", "equals": "=",
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let found = reference(after) {
                out += found.text
                rest = after[found.end...]
            } else {
                out += "&"
                rest = after
            }
        }
        out += rest
        return out
    }

    /// The reference at the start of `s` (after its `&`) and where it ends.
    private static func reference(_ s: Substring) -> (text: String, end: Substring.Index)? {
        if s.first == "#" {
            var digits = s.dropFirst()
            var radix = 10
            if let x = digits.first, x == "x" || x == "X" {
                radix = 16
                digits = digits.dropFirst()
            }
            let number = digits.prefix(while: { $0.isHexDigit && (radix == 16 || $0.isNumber) })
            guard !number.isEmpty, let value = UInt32(number, radix: radix) else { return nil }
            var end = number.endIndex
            if end < s.endIndex, s[end] == ";" { end = s.index(after: end) }
            let scalar = Unicode.Scalar(value) ?? "\u{FFFD}"
            return (String(Character(scalar)), end)
        }
        let name = s.prefix(while: { $0.isLetter || $0.isNumber })
        guard let decoded = named[String(name).lowercased()] else { return nil }
        var end = name.endIndex
        if end < s.endIndex, s[end] == ";" { end = s.index(after: end) }
        return (decoded, end)
    }
}
