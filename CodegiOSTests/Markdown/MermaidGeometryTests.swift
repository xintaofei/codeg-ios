import CoreGraphics
import Foundation
import Testing
@testable import Codeg

// Ported from the web's `mermaid-view.test.ts` (zoom / size helpers) and
// `mermaid-export.test.ts` (raster size, export file names), plus the inline
// picture's size math.

/// A realistic Mermaid 11 root tag: `width="100%"`, the real size only in the
/// viewBox, and an inline `max-width` that would cap every zoom above fit.
private let mermaidSVG =
    #"<svg aria-roledescription="flowchart-v2" viewBox="0 0 780 1240" "# +
    #"style="max-width: 780px; background-color: transparent;" "# +
    #"width="100%" id="mermaid-1" xmlns="http://www.w3.org/2000/svg">"# +
    "<g></g></svg>"

@Suite("Mermaid zoom")
struct MermaidZoomTests {
    @Test func holdsTheZoomInsideTheBounds() {
        #expect(MermaidGeometry.clampZoom(0) == MermaidGeometry.minZoom)
        #expect(MermaidGeometry.clampZoom(1000) == MermaidGeometry.maxZoom)
        #expect(MermaidGeometry.clampZoom(1.5) == 1.5)
    }

    @Test func fallsBackTo1ForANonFiniteZoom() {
        #expect(MermaidGeometry.clampZoom(.nan) == 1)
        #expect(MermaidGeometry.clampZoom(.infinity) == 1)
    }

    @Test func fitZoomShrinksADiagramWiderThanTheColumn() {
        #expect(abs(MermaidGeometry.fitZoom(naturalWidth: 1000, viewportWidth: 500) - 0.5) < 1e-9)
    }

    @Test func fitZoomNeverBlowsANarrowDiagramUp() {
        #expect(MermaidGeometry.fitZoom(naturalWidth: 200, viewportWidth: 800) == 1)
    }

    @Test func fitZoomStaysAt1BeforeTheViewportIsMeasured() {
        #expect(MermaidGeometry.fitZoom(naturalWidth: 800, viewportWidth: 0) == 1)
        #expect(MermaidGeometry.fitZoom(naturalWidth: 0, viewportWidth: 800) == 1)
    }

    @Test func fitZoomDoesNotFitBelowTheMinimumZoom() {
        #expect(MermaidGeometry.fitZoom(naturalWidth: 100_000, viewportWidth: 300) == MermaidGeometry.minZoom)
    }

    @Test func containZoomFitsTheLimitingAxis() {
        // Tall diagram in a wide box: height decides.
        let tall = MermaidGeometry.containZoom(natural: CGSize(width: 500, height: 1000),
                                               viewport: CGSize(width: 1200, height: 800))
        #expect(abs(tall - 0.8) < 1e-9)
        // Wide diagram in a tall box: width decides.
        let wide = MermaidGeometry.containZoom(natural: CGSize(width: 2000, height: 400),
                                               viewport: CGSize(width: 1000, height: 900))
        #expect(abs(wide - 0.5) < 1e-9)
    }

    @Test func containZoomNeverBlowsASmallDiagramUp() {
        #expect(MermaidGeometry.containZoom(natural: CGSize(width: 200, height: 100),
                                            viewport: CGSize(width: 1200, height: 800)) == 1)
    }

    @Test func containZoomStaysAt1WhileAnyDimensionIsUnmeasured() {
        #expect(MermaidGeometry.containZoom(natural: CGSize(width: 500, height: 500),
                                            viewport: CGSize(width: 0, height: 800)) == 1)
        #expect(MermaidGeometry.containZoom(natural: CGSize(width: 0, height: 500),
                                            viewport: CGSize(width: 800, height: 800)) == 1)
    }
}

@Suite("parseSvgSize")
struct ParseSvgSizeTests {
    @Test func readsTheNaturalSizeFromTheViewBox() {
        #expect(MermaidGeometry.parseSvgSize(mermaidSVG) == CGSize(width: 780, height: 1240))
    }

    @Test func acceptsACommaSeparatedViewBox() {
        #expect(MermaidGeometry.parseSvgSize(#"<svg viewBox="0,0,10,20"></svg>"#) == CGSize(width: 10, height: 20))
    }

    @Test func fallsBackToPixelWidthAndHeightAttributes() {
        #expect(MermaidGeometry.parseSvgSize(#"<svg width="300" height="150"></svg>"#)
                == CGSize(width: 300, height: 150))
        #expect(MermaidGeometry.parseSvgSize(#"<svg width="300px" height="150"></svg>"#)
                == CGSize(width: 300, height: 150))
    }

    @Test func ignoresAPercentageWidthWithNoUsableViewBox() {
        #expect(MermaidGeometry.parseSvgSize(#"<svg width="100%" height="100%"></svg>"#) == nil)
    }

    @Test func rejectsADegenerateViewBoxAndMarkupWithNoSvgTag() {
        #expect(MermaidGeometry.parseSvgSize(#"<svg viewBox="0 0 0 0"></svg>"#) == nil)
        #expect(MermaidGeometry.parseSvgSize("<div>not a diagram</div>") == nil)
    }
}

@Suite("stripSvgMaxWidth")
struct StripSvgMaxWidthTests {
    @Test func removesOnlyTheMaxWidthDeclarationFromTheRootTag() {
        let stripped = MermaidGeometry.stripSvgMaxWidth(mermaidSVG)
        #expect(!stripped.lowercased().contains("max-width"))
        // Everything else on the tag survives.
        #expect(stripped.contains("background-color: transparent"))
        #expect(stripped.contains(#"viewBox="0 0 780 1240""#))
        #expect(stripped.contains(#"width="100%""#))
    }

    @Test func leavesNestedStylesAlone() {
        let svg = #"<svg viewBox="0 0 10 10" style="max-width: 10px;"><style>.node{max-width:5px}</style></svg>"#
        #expect(MermaidGeometry.stripSvgMaxWidth(svg).contains(".node{max-width:5px}"))
    }

    @Test func isANoOpWhenThereIsNothingToStrip() {
        let svg = #"<svg viewBox="0 0 10 10"></svg>"#
        #expect(MermaidGeometry.stripSvgMaxWidth(svg) == svg)
    }
}

@Suite("Mermaid export")
struct MermaidExportTests {
    private let svg =
        #"<svg xmlns="http://www.w3.org/2000/svg" aria-roledescription="flowchart-v2" "# +
        #"viewBox="0 0 400 250" style="max-width: 400px; background-color: transparent;" "# +
        #"width="100%" id="mermaid-1"><g><rect width="10" height="10"/></g></svg>"#

    @Test func namesTheFilesAsTheWebDoes() {
        #expect(MermaidExport.fileName(.png) == "diagram.png")
        #expect(MermaidExport.fileName(.svg) == "diagram.svg")
        #expect(MermaidExport.fileName(.mmd) == "diagram.mmd")
        #expect(MermaidExport.fileName(.svg, baseName: "flow") == "flow.svg")
    }

    @Test func takesThePixelSizeFromTheViewBoxAndScalesIt() {
        #expect(MermaidExport.rasterSize(svg: svg, scale: 3) == CGSize(width: 1200, height: 750))
        #expect(MermaidExport.pngScale == 3)
    }

    @Test func neverReadsMermaidsHundredPercentWidthAsHundredPixels() {
        let percent = #"<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%"></svg>"#
        #expect(MermaidExport.rasterSize(svg: percent, scale: 3) == nil)
    }

    @Test func fallsBackToAbsoluteWidthAndHeightAttributes() {
        let absolute = #"<svg xmlns="http://www.w3.org/2000/svg" width="300px" height="150"></svg>"#
        #expect(MermaidExport.rasterSize(svg: absolute, scale: 2) == CGSize(width: 600, height: 300))
    }

    @Test func returnsNilForADegenerateViewBoxOrNonSvgMarkup() {
        #expect(MermaidExport.rasterSize(svg: #"<svg viewBox="0 0 0 0"></svg>"#, scale: 3) == nil)
        #expect(MermaidExport.rasterSize(svg: "<div>not a diagram</div>", scale: 3) == nil)
        #expect(MermaidExport.rasterSize(svg: "", scale: 3) == nil)
    }

    @Test func roundsTheRasterSizeToWholePixels() {
        let fractional = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100.4 33.3"></svg>"#
        #expect(MermaidExport.rasterSize(svg: fractional, scale: 1.5) == CGSize(width: 151, height: 50))
    }
}

@Suite("inline diagram size")
struct InlineDiagramSizeTests {
    @Test func fitsAWideDiagramToTheColumn() {
        #expect(MermaidGeometry.inlineWidth(natural: CGSize(width: 1000, height: 500), column: 360) == 360)
    }

    @Test func keepsANarrowDiagramAtItsOwnWidth() {
        #expect(MermaidGeometry.inlineWidth(natural: CGSize(width: 200, height: 500), column: 360) == 200)
    }

    @Test func fitsEvenPastTheZoomFloor() {
        // The inline picture is not pannable: no 0.2 floor as in `fitZoom`.
        #expect(MermaidGeometry.inlineWidth(natural: CGSize(width: 100_000, height: 50), column: 300) == 300)
    }

    @Test func takesTheColumnWithoutANaturalSize() {
        #expect(MermaidGeometry.inlineWidth(natural: nil, column: 320) == 320)
        #expect(MermaidGeometry.inlineWidth(natural: CGSize(width: 400, height: 300), column: 0) == 0)
    }

    @Test func capsTheHeightAndFadesOnlyWhenSomethingIsCut() {
        let clip = MermaidGeometry.inlineClip(drawnHeight: 1800, maxHeight: 500)
        #expect(clip == 500)
        #expect(MermaidGeometry.isClipped(drawnHeight: 1800, clipHeight: clip))
        let short = MermaidGeometry.inlineClip(drawnHeight: 240, maxHeight: 500)
        #expect(short == 240)
        #expect(!MermaidGeometry.isClipped(drawnHeight: 240, clipHeight: short))
        // Under a pixel of overhang is not "more below".
        #expect(!MermaidGeometry.isClipped(drawnHeight: 500.6, clipHeight: 500))
    }
}

@Suite("pixel budget")
struct PixelBudgetTests {
    @Test func keepsThePreferredScaleWithinBudget() {
        #expect(PixelBudget.scale(for: CGSize(width: 400, height: 300), preferred: 3, maxPixels: 8_000_000) == 3)
    }

    @Test func lowersTheScaleToStayWithinThePixelBudget() {
        let size = CGSize(width: 2000, height: 4000)
        let scale = PixelBudget.scale(for: size, preferred: 3, maxPixels: 16_000_000)
        #expect(scale < 3)
        #expect(size.width * size.height * scale * scale <= 16_000_000 * 1.0001)
    }

    @Test func lowersTheScaleToStayWithinTheMaximumSide() {
        let scale = PixelBudget.scale(for: CGSize(width: 10_000, height: 10), preferred: 3,
                                      maxPixels: 1e12, maxSide: 8192)
        #expect(abs(scale - 0.8192) < 1e-9)
    }
}
