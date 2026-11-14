import SwiftUI

/// A parsed block of Markdown. Inline spans (bold, italic, code, links) are
/// pre-parsed into `AttributedString` at parse time so the whole block list can
/// be cached per source string — the recycling `List` then re-displays a turn
/// for free. Fenced code keeps its raw text (rendered by `CodeBlockView`).
enum MarkdownBlock {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    /// Consecutive list items. Nested items of either kind belong to the list
    /// they are nested in; at the top level a switch between bullets and
    /// numbers starts a new list.
    case list([MarkdownListItem])
    case quote([AttributedString])
    /// A fenced code block. `closed` once its closing fence has arrived — a
    /// streaming reply's last fence is open until then (and a reply that ends
    /// mid-fence stays open). Renderers that must not draw half a source
    /// (Mermaid, HTML, json-render) wait for it.
    case code(language: String?, code: String, closed: Bool)
    case rule
    case table(header: [AttributedString], rows: [[AttributedString]])
    /// An image, lifted out of its paragraph to stand on its own.
    case image(MarkdownImageRef)
}

/// One list item: its marker, its nesting depth, and — for a GFM task item —
/// whether it is checked.
struct MarkdownListItem {
    enum Marker: Equatable {
        case bullet
        /// The item's number as written, normalised to `N.`.
        case ordered(String)
    }

    let marker: Marker
    /// 0 (top level) to `MarkdownContent.maxListLevel`.
    let level: Int
    /// `- [ ] …` → false, `- [x] …` → true; nil for an ordinary item.
    let checked: Bool?
    let content: AttributedString
}

/// Block-level Markdown for finalized assistant text. Unlike `MarkdownText`
/// (Apple's *inline-only* parser, which leaves ``` fences as literal backticks),
/// this splits the source into real blocks — paragraphs, headings, lists,
/// quotes, fenced code, rules, GFM tables — so a coding agent's replies render
/// like a chat client instead of a wall of text. Inline content inside each
/// block still goes through `MarkdownText.attributed(from:)` for bold/italic/
/// inline-code/links.
///
/// Streaming text uses this too, via `LiveTextNode` with `streaming: true`, which
/// parses directly and bypasses the block cache (the partial strings would only
/// churn it); the finalized turn re-renders once through the cached path.
///
/// Images render as blocks of their own (`MarkdownImageBlock`), loaded through
/// the transcript's `MarkdownImageLoader` when there is one in the environment;
/// GFM task items draw a checkbox in place of their bullet. Fences that claim a
/// renderer of their own (Mermaid, json-render, HTML previews) are routed by
/// `MarkdownFence`.
struct MarkdownContent: View {
    let raw: String
    /// While a reply is streaming, parse directly (skip the block LRU): the text
    /// changes ~20×/sec, so caching every partial string would only churn (and
    /// evict useful finalized entries). The finalized turn re-renders once through
    /// the cached path.
    var streaming: Bool = false
    /// This is an assistant reply's own text — the one place a ```` ```spec ````
    /// fence is a json-render card rather than code (as on the web, where
    /// `JsonRenderScope` wraps only reply text: not user messages, tool output
    /// or reasoning).
    var assistantReply: Bool = false

    /// "Render HTML in chat": an assistant reply's closed ```` ```html ````
    /// fences draw as previews.
    @Environment(\.chatHtmlRendering) private var htmlRendering

    /// Deepest list nesting drawn; deeper items draw at this depth.
    static let maxListLevel = 4
    /// Marker column (14) + its spacing (6): a nested item's marker sits under
    /// its parent's text.
    private static let listIndent: CGFloat = 20

    private var blocks: [MarkdownBlock] {
        streaming ? MarkdownContent.parseBlocks(raw) : MarkdownContent.blocks(for: raw)
    }

    var body: some View {
        let parsed = blocks
        let lastIndex = parsed.count - 1
        VStack(alignment: .leading, spacing: Theme.Typography.blockSpacing) {
            ForEach(Array(parsed.enumerated()), id: \.offset) { idx, block in
                // Streaming "typing" caret rides the trailing paragraph only —
                // a code/list/table tail is self-evidently in progress already.
                view(for: block, caret: streaming && idx == lastIndex && Self.isParagraph(block),
                     isLast: idx == lastIndex)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func isParagraph(_ block: MarkdownBlock) -> Bool {
        if case .paragraph = block { return true }
        return false
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock, caret: Bool = false, isLast: Bool = false) -> some View {
        switch block {
        case .paragraph(let a):
            if caret {
                CaretParagraph(base: a)
            } else {
                Text(a)
                    .font(Theme.Typography.messageBody)
                    .lineSpacing(Theme.Typography.messageLineSpacing)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .tint(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .heading(let level, let a):
            Text(a)
                .font(Theme.Typography.heading(level))
                .lineSpacing(Theme.Typography.headingLineSpacing)
                .fontWeight(Theme.Typography.headingWeight(level))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)

        case .list(let items):
            VStack(alignment: .leading, spacing: Theme.Typography.listItemSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(item)
                }
            }

        case .quote(let items):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.5)).frame(width: 3)
                VStack(alignment: .leading, spacing: Theme.Typography.listItemSpacing) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Text(item)
                            .font(Theme.Typography.quote)
                            .lineSpacing(Theme.Typography.quoteLineSpacing)
                            .foregroundStyle(Theme.textSecondary)
                            .italic()
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .code(let lang, let code, let closed):
            // A folded spec card is fine while the fence is still arriving, and
            // plain code always is; a diagram waits for its final source.
            let settled = MarkdownFence.isSettled(closed: closed, streaming: streaming, isLastBlock: isLast,
                                                  sourceEndsWithNewline: raw.hasSuffix("\n"))
            switch MarkdownFence.kind(language: lang, code: code, closed: closed, settled: settled,
                                      assistantReply: assistantReply, htmlEnabled: htmlRendering) {
            case .mermaid(let ready):
                MermaidBlock(source: code, ready: ready)
            case .htmlPreview:
                HtmlPreviewBlock(source: code)
            case .spec:
                SpecFenceCard(source: code)
            case .code:
                CodeBlockView(code: code, language: lang)
            }

        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.vertical, 2)

        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)

        case .image(let image):
            MarkdownImageBlock(image: image)
        }
    }

    private func listRow(_ item: MarkdownListItem) -> some View {
        // First-baseline, not top: a task item's checkbox is a symbol, and
        // its baseline is what lines it up with the first line of text.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            listMarker(item)
                // Marker hugs the block's left edge (no leading indent) so lists
                // line up with paragraphs/headings; the small min-width keeps
                // multi-line item text aligned past the marker.
                .frame(minWidth: 14, alignment: .leading)
            Text(item.content)
                .font(Theme.Typography.messageBody)
                .lineSpacing(Theme.Typography.messageLineSpacing)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .tint(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(item.level) * Self.listIndent)
        .modifier(TaskItemAccessibility(checked: item.checked))
    }

    /// The bullet or number — or, for a task item, a read-only checkbox in its
    /// place (checked items are not struck through, as on the web).
    @ViewBuilder
    private func listMarker(_ item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(Theme.Typography.messageBody)
                .foregroundStyle(checked ? Theme.accent : Theme.textTertiary)
                .accessibilityHidden(true)
        } else {
            Text(verbatim: Self.markerText(item))
                .font(Theme.Typography.messageBody)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// `•` at even depths and `◦` at odd ones; numbers as written.
    static func markerText(_ item: MarkdownListItem) -> String {
        switch item.marker {
        case .bullet: return item.level.isMultiple(of: 2) ? "•" : "◦"
        case .ordered(let number): return number
        }
    }
}

/// A task item reads as one element with its state as the value — the
/// checkbox glyph itself is hidden from VoiceOver.
private struct TaskItemAccessibility: ViewModifier {
    let checked: Bool?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let checked {
            content
                .accessibilityElement(children: .combine)
                .accessibilityValue(checked ? Text("Completed") : Text("Not completed"))
        } else {
            content
        }
    }
}

// MARK: - Streaming caret

/// The trailing paragraph of a still-streaming reply, with a blinking "typing"
/// caret glued to the end of the text (so it wraps with the last word, like
/// ChatGPT). The caret glyph is *always* in the layout (constant width — only
/// its color alpha toggles), so the blink never re-measures the line box.
///
/// The blink is a discrete timer toggle with NO animation — deliberately. An
/// *ambient* `withAnimation(.repeatForever)` would make every concurrent layout
/// change animate too, so each streamed token would interpolate the caret's
/// x-position across the line (it visibly flew right). A hard terminal-style
/// blink keeps the caret pinned to the text end at every frame. `textSelection`
/// is omitted: streaming text isn't selected mid-flight.
private struct CaretParagraph: View {
    let base: AttributedString
    @State private var visible = true

    private var caretRun: AttributedString {
        var s = AttributedString(" ▌")
        s.foregroundColor = visible ? Theme.accent : Theme.accent.opacity(0)
        return s
    }

    var body: some View {
        (Text(base) + Text(caretRun))
            .font(Theme.Typography.messageBody)
            .lineSpacing(Theme.Typography.messageLineSpacing)
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.accent)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(530))
                    visible.toggle()
                }
            }
    }
}

// MARK: - Table fallback

/// A minimal GFM table: fixed-width columns in a horizontally scrollable grid.
/// Not a full layout engine — just enough that a table reads as a table.
private struct MarkdownTable: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(header, isHeader: true)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, cells in
                    row(cells, isHeader: false)
                    if idx < rows.count - 1 {
                        Rectangle().fill(Theme.hairline.opacity(0.5)).frame(height: 0.5)
                    }
                }
            }
            .background(Color(light: .black.opacity(0.05), dark: .black.opacity(0.18)), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .hairlineBorder(Theme.Radius.sm)
        }
    }

    private func row(_ cells: [AttributedString], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell)
                    .font(.caption)
                    .fontWeight(isHeader ? .semibold : .regular)
                    .foregroundStyle(isHeader ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 130, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
    }
}

// MARK: - Parsing + cache

extension MarkdownContent {
    /// Parse into blocks, memoized per source string (block parsing is heavier
    /// than inline; the cache keeps recycled `List` rows free). Main-thread-only,
    /// like `MarkdownText`'s cache.
    static func blocks(for raw: String) -> [MarkdownBlock] {
        if let hit = cache[raw] { return hit }
        let parsed = parseBlocks(raw)
        cache[raw] = parsed
        order.append(raw)
        if order.count > limit {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return parsed
    }

    private static var cache: [String: [MarkdownBlock]] = [:]
    private static var order: [String] = []
    private static let limit = 300

    static func parseBlocks(_ raw: String) -> [MarkdownBlock] {
        let lines = raw.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0
        func inline(_ s: String) -> AttributedString { MarkdownText.attributed(from: s) }

        /// A paragraph, cut at its images: each image becomes a block of its
        /// own between the text around it.
        func appendParagraph(_ text: String) {
            guard let segments = MarkdownInlineImages.split(text) else {
                blocks.append(.paragraph(inline(text)))
                return
            }
            for segment in segments {
                switch segment {
                case .text(let piece):
                    let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { blocks.append(.paragraph(inline(trimmed))) }
                case .image(let image):
                    blocks.append(.image(image))
                }
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block. It closes on a fence of the same character at
            // least as long as the opening one (so a ```` fence can show ```
            // inside it); its lines lose the opening fence's indentation, as in
            // a fence nested in a list item.
            if let fence = fenceOpening(trimmed) {
                let indent = leadingSpaces(line)
                var bodyLines: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if closesFence(t, fence) { closed = true; i += 1; break }
                    bodyLines.append(dropLeadingSpaces(lines[i], upTo: indent)); i += 1
                }
                blocks.append(.code(language: fence.info.isEmpty ? nil : fence.info,
                                    code: bodyLines.joined(separator: "\n"),
                                    closed: closed))
                continue
            }

            if trimmed.isEmpty { i += 1; continue }

            if let (level, rest) = heading(trimmed) {
                blocks.append(.heading(level: level, inline(rest))); i += 1; continue
            }

            if isRule(trimmed) {
                blocks.append(.rule); i += 1; continue
            }

            // Blockquote (consecutive `>` lines).
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote([inline(quoted.joined(separator: "\n"))]))
                continue
            }

            // GFM table (header row + a `|---|` separator).
            if i + 1 < lines.count, line.contains("|"), isTableSeparator(lines[i + 1]) {
                let header = tableCells(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[i])); i += 1
                }
                blocks.append(.table(header: header.map(inline), rows: rows.map { $0.map(inline) }))
                continue
            }

            // List: consecutive bullet / numbered items. Each item's depth comes
            // from its indentation relative to the items above it (any step —
            // 2, 3 or 4 columns — opens a level), capped at `maxListLevel`.
            if let first = listLine(trimmed) {
                var items: [MarkdownListItem] = []
                var indents: [Int] = []
                while i < lines.count {
                    let itemLine = lines[i]
                    guard let item = listLine(itemLine.trimmingCharacters(in: .whitespaces)) else { break }
                    var open = indents
                    let level = nestingLevel(indentWidth(itemLine), open: &open)
                    // Back at the top level, bullets and numbers are two lists.
                    if level == 0, !items.isEmpty, item.ordered != first.ordered { break }
                    indents = open
                    let task = taskMarker(item.content)
                    items.append(MarkdownListItem(
                        marker: item.ordered ? .ordered(item.marker) : .bullet,
                        level: min(level, maxListLevel),
                        checked: task?.checked,
                        content: inline(task?.rest ?? item.content)
                    ))
                    i += 1
                }
                blocks.append(.list(items))
                continue
            }

            // Paragraph: gather until a blank line or the start of another block.
            var para: [String] = []
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if fenceOpening(t) != nil { break }
                if heading(t) != nil { break }
                if isRule(t) { break }
                if t.hasPrefix(">") { break }
                if listLine(t) != nil { break }
                if i + 1 < lines.count, l.contains("|"), isTableSeparator(lines[i + 1]) { break }
                para.append(l); i += 1
            }
            if !para.isEmpty { appendParagraph(para.joined(separator: "\n")) }
        }
        return blocks
    }

    // MARK: line classifiers

    /// An opening code fence: three or more backticks or tildes, then the info
    /// string. A backtick fence's info string can't contain a backtick (that
    /// line is inline code, not a fence).
    struct Fence {
        let character: Character
        let length: Int
        let info: String
    }

    static func fenceOpening(_ trimmed: String) -> Fence? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let length = trimmed.prefix(while: { $0 == first }).count
        guard length >= 3 else { return nil }
        let info = String(trimmed.dropFirst(length)).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        return Fence(character: first, length: length, info: info)
    }

    private static func closesFence(_ trimmed: String, _ fence: Fence) -> Bool {
        trimmed.count >= fence.length && trimmed.allSatisfy { $0 == fence.character }
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var n = 0
        for u in line.unicodeScalars {
            guard u == " " else { break }
            n += 1
        }
        return n
    }

    private static func dropLeadingSpaces(_ line: String, upTo limit: Int) -> String {
        guard limit > 0 else { return line }
        var idx = line.startIndex
        var dropped = 0
        while dropped < limit, idx < line.endIndex, line[idx] == " " {
            idx = line.index(after: idx)
            dropped += 1
        }
        return dropped == 0 ? line : String(line[idx...])
    }

    /// Leading indentation in columns (a tab advances to the next multiple of 4).
    static func indentWidth(_ line: String) -> Int {
        var width = 0
        for u in line.unicodeScalars {
            if u == " " {
                width += 1
            } else if u == "\t" {
                width = (width / 4 + 1) * 4
            } else {
                break
            }
        }
        return width
    }

    /// The depth of an item indented `indent` columns, given the indents of
    /// the levels open above it (updated in place): deeper than the innermost
    /// opens a level, otherwise it closes levels until one is no deeper than
    /// it. An item left of the list's first one stays at the top level, and
    /// becomes the indent the top level is measured from.
    static func nestingLevel(_ indent: Int, open: inout [Int]) -> Int {
        guard let innermost = open.last else {
            open = [indent]
            return 0
        }
        if indent > innermost {
            open.append(indent)
            return open.count - 1
        }
        while open.count > 1, indent < open[open.count - 1] { open.removeLast() }
        if indent < open[0] { open[0] = indent }
        if indent > open[open.count - 1] { open.append(indent) }
        return open.count - 1
    }

    private struct ListLine {
        let ordered: Bool
        /// `N.` for a numbered item; unused for a bullet.
        let marker: String
        let content: String
    }

    private static func listLine(_ trimmed: String) -> ListLine? {
        if let content = bulletContent(trimmed) {
            return ListLine(ordered: false, marker: "", content: dropLeadingBlanks(content))
        }
        if let (marker, content) = orderedContent(trimmed) {
            return ListLine(ordered: true, marker: marker, content: dropLeadingBlanks(content))
        }
        return nil
    }

    private static func dropLeadingBlanks(_ s: String) -> String {
        guard let first = s.first, first == " " || first == "\t" else { return s }
        return String(s.drop(while: { $0 == " " || $0 == "\t" }))
    }

    /// A GFM task item's `[ ]` / `[x]` / `[X]` and the whitespace after it.
    static func taskMarker(_ content: String) -> (checked: Bool, rest: String)? {
        let head = Array(content.unicodeScalars.prefix(4))
        guard head.count == 4, head[0] == "[", head[2] == "]",
              head[1] == " " || head[1] == "x" || head[1] == "X",
              head[3] == " " || head[3] == "\t" else { return nil }
        let rest = String(content.unicodeScalars.dropFirst(4))
        return (head[1] != " ", dropLeadingBlanks(rest))
    }

    private static func heading(_ trimmed: String) -> (Int, String)? {
        var n = 0
        for ch in trimmed { if ch == "#" { n += 1 } else { break } }
        guard (1...6).contains(n) else { return nil }
        let rest = String(trimmed.dropFirst(n))
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return (n, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let s = trimmed.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3 else { return false }
        return s.allSatisfy { $0 == "-" } || s.allSatisfy { $0 == "*" } || s.allSatisfy { $0 == "_" }
    }

    private static func bulletContent(_ trimmed: String) -> String? {
        for p in ["- ", "* ", "+ "] where trimmed.hasPrefix(p) {
            return String(trimmed.dropFirst(2))
        }
        return nil
    }

    private static func orderedContent(_ trimmed: String) -> (String, String)? {
        var digits = ""
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx].isNumber {
            digits.append(trimmed[idx]); idx = trimmed.index(after: idx)
        }
        guard !digits.isEmpty, idx < trimmed.endIndex else { return nil }
        let sep = trimmed[idx]
        guard sep == "." || sep == ")" else { return nil }
        let after = trimmed.index(after: idx)
        guard after < trimmed.endIndex, trimmed[after] == " " else { return nil }
        return (digits + ".", String(trimmed[trimmed.index(after: after)...]))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
