import CoreGraphics
import Foundation

/// Mermaid's theme for one color scheme — the web's `{ theme: isDarkMode ?
/// "dark" : "default" }`. Part of every cache key: a diagram drawn for one
/// scheme is never shown in the other.
struct MermaidTheme: Hashable, Sendable {
    let dark: Bool

    /// The `theme` Mermaid is initialized with.
    var name: String { dark ? "dark" : "default" }
}

/// One rendered Mermaid source, for one theme: the SVG markup (with the root's
/// inline `max-width` removed, as the web's `stripSvgMaxWidth`) and its natural
/// size in CSS pixels, when the SVG declares one.
struct MermaidDiagram: Sendable, Equatable {
    let svg: String
    let natural: CGSize?
}

/// Size and zoom helpers ported from the web's `mermaid-view.ts`. Kept free of
/// views and WebKit so they are tested directly.
enum MermaidGeometry {
    static let minZoom: CGFloat = 0.2
    static let maxZoom: CGFloat = 8

    static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return 1 }
        return min(maxZoom, max(minZoom, zoom))
    }

    /// Zoom at which a diagram `naturalWidth` wide fills `viewportWidth`,
    /// capped at 1 (a narrow diagram keeps its own size).
    static func fitZoom(naturalWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        guard naturalWidth > 0, viewportWidth > 0 else { return 1 }
        return clampZoom(min(1, viewportWidth / naturalWidth))
    }

    /// Zoom at which the whole diagram fits inside `viewport`, capped at 1.
    static func containZoom(natural: CGSize, viewport: CGSize) -> CGFloat {
        guard natural.width > 0, natural.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return clampZoom(min(1, viewport.width / natural.width, viewport.height / natural.height))
    }

    /// The width a diagram is drawn at in a column `column` wide: its natural
    /// width, scaled down — never up — to the column. Unlike `fitZoom` there is
    /// no lower bound: the inline picture is not pannable, so it always fits.
    /// A diagram with no natural size takes the column.
    static func inlineWidth(natural: CGSize?, column: CGFloat) -> CGFloat {
        guard column > 0 else { return 0 }
        guard let natural, natural.width > 0 else { return column }
        return min(natural.width, column)
    }

    /// The height of the inline picture: the drawn height, capped at
    /// `maxHeight` (the web's `max-h-[60vh]`).
    static func inlineClip(drawnHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        max(1, min(drawnHeight, maxHeight))
    }

    /// There is diagram below the cap — the web fades the clipped edge then.
    static func isClipped(drawnHeight: CGFloat, clipHeight: CGFloat) -> Bool {
        drawnHeight > clipHeight + 1
    }

    // MARK: SVG

    private static let svgTag = regex(#"<svg\b[^>]*>"#)
    private static let viewBoxAttr = regex(#"\bviewBox\s*=\s*["']([^"']*)["']"#)
    private static let widthAttr = regex(#"\bwidth\s*=\s*["']([^"']*)["']"#)
    private static let heightAttr = regex(#"\bheight\s*=\s*["']([^"']*)["']"#)
    private static let pixelValue = regex(#"^\s*(-?[\d.]+)(px)?\s*$"#)
    private static let styleAttr = regex(#"\bstyle\s*=\s*(["'])([\s\S]*?)\1"#)
    private static let maxWidthDecl = regex(#"(?:^|;)\s*max-width\s*:[^;]*"#)
    private static let edgeSemicolons = regex(#"^;+|;+$"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals: a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// The natural size of a rendered SVG, in CSS pixels (`parseSvgSize`).
    /// Mermaid's root carries `width="100%"` and the real size in its
    /// `viewBox`, so the viewBox decides; absolute `width`/`height` attributes
    /// are the fallback. Percentages never count.
    static func parseSvgSize(_ svg: String) -> CGSize? {
        let ns = svg as NSString
        guard let tagMatch = svgTag.firstMatch(in: svg, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let tag = ns.substring(with: tagMatch.range)
        if let viewBox = firstGroup(viewBoxAttr, in: tag) {
            let parts = viewBox.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map { jsNumber(String($0)) }
            if parts.count == 4, finitePositive(parts[2]), finitePositive(parts[3]) {
                return CGSize(width: parts[2], height: parts[3])
            }
        }
        guard let width = pixelAttr(firstGroup(widthAttr, in: tag)),
              let height = pixelAttr(firstGroup(heightAttr, in: tag)) else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Drop the inline `max-width` Mermaid puts on the root `<svg>`
    /// (`stripSvgMaxWidth`). Only the root tag's `style` is touched.
    static func stripSvgMaxWidth(_ svg: String) -> String {
        let ns = svg as NSString
        guard let tagMatch = svgTag.firstMatch(in: svg, range: NSRange(location: 0, length: ns.length)) else {
            return svg
        }
        let tag = ns.substring(with: tagMatch.range) as NSString
        guard let style = styleAttr.firstMatch(in: tag as String, range: NSRange(location: 0, length: tag.length)) else {
            return svg
        }
        let quote = tag.substring(with: style.range(at: 1))
        let css = tag.substring(with: style.range(at: 2))
        let withoutMaxWidth = replacingAll(maxWidthDecl, in: css, with: ";")
        let next = replacingAll(edgeSemicolons, in: withoutMaxWidth, with: "")
        let newTag = tag.replacingCharacters(in: style.range, with: "style=\(quote)\(next)\(quote)")
        return ns.replacingCharacters(in: tagMatch.range, with: newTag)
    }

    private static func replacingAll(_ regex: NSRegularExpression, in string: String, with literal: String) -> String {
        regex.stringByReplacingMatches(
            in: string, range: NSRange(location: 0, length: (string as NSString).length),
            withTemplate: NSRegularExpression.escapedTemplate(for: literal))
    }

    private static func firstGroup(_ regex: NSRegularExpression, in string: String) -> String? {
        let ns = string as NSString
        guard let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// A bare number or an explicit `px` — `"100%"` is not 100 pixels.
    private static func pixelAttr(_ raw: String?) -> CGFloat? {
        guard let raw, let number = firstGroup(pixelValue, in: raw) else { return nil }
        let value = parseFloat(number)
        return finitePositive(value) ? value : nil
    }

    private static func finitePositive(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0
    }

    /// JavaScript `Number(s)` for a viewBox part: empty is 0, junk is NaN.
    private static func jsNumber(_ s: String) -> CGFloat {
        if s.isEmpty { return 0 }
        return Double(s).map { CGFloat($0) } ?? .nan
    }

    /// JavaScript `parseFloat` on `[-]digits/dots`: the longest prefix that
    /// reads as a number (`"1.2.3"` is 1.2).
    private static func parseFloat(_ s: String) -> CGFloat {
        var prefix = s
        while !prefix.isEmpty {
            if let value = Double(prefix) { return CGFloat(value) }
            prefix.removeLast()
        }
        return .nan
    }
}

/// The diagram's toolbar exports (`mermaid-export.ts`): the rendered SVG, a PNG
/// at three times the diagram's own size, and the fence source.
enum MermaidExport {
    enum Format: String {
        case svg, png, mmd
    }

    /// Multiplier applied to the diagram's own size when rasterizing to PNG.
    static let pngScale: CGFloat = 3
    /// The PNG's bitmap stays within this many pixels…
    static let maxPixels: CGFloat = 16_000_000
    /// …and this many on its long side.
    static let maxSide: CGFloat = 8192

    /// `${baseName}.${format}` — `diagram.svg`, `diagram.png`, `diagram.mmd`.
    static func fileName(_ format: Format, baseName: String = "diagram") -> String {
        "\(baseName).\(format.rawValue)"
    }

    /// The PNG's pixel size (`sizeSvgForRaster`): the natural size times
    /// `scale`, rounded to whole pixels; nil when the SVG has no usable size.
    static func rasterSize(svg: String, scale: CGFloat) -> CGSize? {
        guard let natural = MermaidGeometry.parseSvgSize(svg), scale > 0 else { return nil }
        return CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }
}

/// How many pixels per point a picture is drawn at: the wanted scale, lowered
/// so its bitmap stays within a pixel budget and a maximum side.
enum PixelBudget {
    static func scale(for size: CGSize, preferred: CGFloat, maxPixels: CGFloat, maxSide: CGFloat = 8192) -> CGFloat {
        guard size.width > 0, size.height > 0, preferred > 0 else { return max(0, preferred) }
        let byArea = (maxPixels / (size.width * size.height)).squareRoot()
        let bySide = maxSide / max(size.width, size.height)
        return min(preferred, byArea, bySide)
    }
}
