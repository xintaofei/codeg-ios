import CoreGraphics
import Foundation
import Testing
@testable import Codeg

// The HTML preview's fence routing (closed ```html in an assistant reply, with
// the setting on), its heights (`html-code-preview.tsx`), its cache keys and
// theme, and the per-source view memory.

@Suite("HTML fence routing")
struct HtmlFenceRoutingTests {
    private func kind(_ language: String?, _ code: String = "<p>x</p>", closed: Bool = true, settled: Bool = true,
                      reply: Bool = true, enabled: Bool = true) -> MarkdownFenceKind {
        MarkdownFence.kind(language: language, code: code, closed: closed, settled: settled,
                           assistantReply: reply, htmlEnabled: enabled)
    }

    @Test func previewsAClosedHtmlFenceInAReplyWithTheSettingOn() {
        #expect(kind("html") == .htmlPreview)
        #expect(kind("htm") == .htmlPreview)
        #expect(kind("HTML") == .htmlPreview)
        #expect(kind("html title=card") == .htmlPreview)
    }

    @Test func leavesItAsCodeWithTheSettingOff() {
        #expect(kind("html", enabled: false) == .code)
    }

    @Test func leavesItAsCodeOutsideAnAssistantReply() {
        #expect(kind("html", reply: false) == .code)
    }

    @Test func leavesAnOpenOrUnsettledFenceAsCode() {
        // Still streaming in.
        #expect(kind("html", closed: false, settled: false) == .code)
        // Closed, but its closing line is still arriving.
        #expect(kind("html", closed: true, settled: false) == .code)
        // The reply ended mid-fence: final, but never closed.
        #expect(kind("html", closed: false, settled: true) == .code)
    }

    @Test func leavesAnEmptyFenceAndOtherLanguagesAsCode() {
        #expect(kind("html", "  \n\t") == .code)
        #expect(kind("html5") == .code)
        #expect(kind("xhtml") == .code)
        #expect(kind("vue") == .code)
        #expect(kind(nil) == .code)
    }

    @Test func stillDrawsMermaidWhereverItIs() {
        #expect(kind("mermaid", "graph TD;", reply: false, enabled: false) == .mermaid(ready: true))
    }
}

@Suite("HTML preview heights")
struct HtmlPreviewMetricsTests {
    @Test func clampsTheMeasuredHeightTo96Through12000() {
        #expect(HtmlPreviewMetrics.clamp(50) == 96)
        #expect(HtmlPreviewMetrics.clamp(500.2) == 501)
        #expect(HtmlPreviewMetrics.clamp(20_000) == 12_000)
        #expect(HtmlPreviewMetrics.clamp(640) == 640)
    }

    @Test func keepsTheDefaultHeightWhenThereIsNothingToMeasure() {
        #expect(HtmlPreviewMetrics.clamp(0) == 160)
        #expect(HtmlPreviewMetrics.clamp(-3) == 160)
        #expect(HtmlPreviewMetrics.clamp(.nan) == 160)
        #expect(HtmlPreviewMetrics.clamp(.infinity) == 160)
    }

    @Test func showsAtMost640UntilShowAll() {
        #expect(!HtmlPreviewMetrics.overflows(640))
        #expect(HtmlPreviewMetrics.overflows(641))
        #expect(HtmlPreviewMetrics.visibleHeight(1000, expanded: false) == 640)
        #expect(HtmlPreviewMetrics.visibleHeight(1000, expanded: true) == 1000)
        #expect(HtmlPreviewMetrics.visibleHeight(300, expanded: false) == 300)
        #expect(HtmlPreviewMetrics.visibleHeight(300, expanded: true) == 300)
    }

    @Test func drawsOnlyTheCollapsedPartUntilShowAll() {
        #expect(HtmlPreviewMetrics.pictureClip(expanded: false) == 640)
        #expect(HtmlPreviewMetrics.pictureClip(expanded: true) == 12_000)
        #expect(HtmlPreviewMetrics.placeholderHeight == 160)
    }
}

@Suite("HTML preview cache keys and theme")
struct HtmlPreviewKeyTests {
    private let darkNeutral = ChatHtmlTheme(dark: true, accent: .neutral)

    @Test func theThemeIsPartOfTheKey() {
        let a = WebRenderKey.html(source: "<p>x</p>", theme: darkNeutral, width: 343, clip: 640)
        #expect(a == WebRenderKey.html(source: "<p>x</p>", theme: darkNeutral, width: 343, clip: 640))
        #expect(a != WebRenderKey.html(source: "<p>x</p>", theme: ChatHtmlTheme(dark: false, accent: .neutral),
                                       width: 343, clip: 640))
        #expect(a != WebRenderKey.html(source: "<p>x</p>", theme: ChatHtmlTheme(dark: true, accent: .blue),
                                       width: 343, clip: 640))
    }

    @Test func theWidthAndCoveredHeightArePartOfTheKey() {
        let a = WebRenderKey.html(source: "<p>x</p>", theme: darkNeutral, width: 343, clip: 640)
        #expect(a != WebRenderKey.html(source: "<p>x</p>", theme: darkNeutral, width: 390, clip: 640))
        #expect(a != WebRenderKey.html(source: "<p>x</p>", theme: darkNeutral, width: 343, clip: 12_000))
        #expect(a.hasPrefix(WebRenderKey.htmlDocument(source: "<p>x</p>", theme: darkNeutral)))
        #expect(WebRenderKey.htmlDocument(source: "<p>x</p>", theme: darkNeutral)
                != WebRenderKey.htmlDocument(source: "<p>y</p>", theme: darkNeutral))
    }

    @Test func aDiagramAndAPreviewOfTheSameTextNeverShareAKey() {
        #expect(WebRenderKey.htmlDocument(source: "x", theme: darkNeutral)
                != WebRenderKey.mermaid(source: "x", theme: MermaidTheme(dark: true)))
    }

    @Test func carriesTheThemeTokensWithTheSurfaceAndAccent() {
        let css = darkNeutral.variablesCSS
        #expect(css.hasPrefix(":root{"))
        #expect(css.contains("--background:\(RichBlockPalette(dark: true).css)"))
        #expect(css.contains("--foreground:oklch(0.985 0 0)"))
        #expect(css.contains("--primary:rgb("))
        #expect(css.contains("--ring:rgb("))
        #expect(css.hasSuffix("--viz-series-1:var(--blue)}"))
        let light = ChatHtmlTheme(dark: false, accent: .neutral).variablesCSS
        #expect(light.contains("--foreground:oklch(0.145 0 0)"))
        #expect(light != css)
        #expect(ChatHtmlTheme(dark: true, accent: .blue).variablesCSS != css)
        #expect(darkNeutral.key == "dark-\(AccentPalette.neutral.rawValue)")
    }
}

@MainActor
@Suite("HTML preview view memory")
struct HtmlPreviewViewMemoryTests {
    @Test func defaultsToTheCollapsedPreview() {
        let memory = HtmlPreviewViewMemory()
        #expect(memory.choice(for: "<p>new</p>") == .init(preview: true, expanded: false))
    }

    @Test func remembersTheChoicePerSource() {
        let memory = HtmlPreviewViewMemory()
        memory.remember(.init(preview: false, expanded: false), for: "<p>a</p>")
        memory.remember(.init(preview: true, expanded: true), for: "<p>b</p>")
        #expect(memory.choice(for: "<p>a</p>") == .init(preview: false, expanded: false))
        #expect(memory.choice(for: "<p>b</p>") == .init(preview: true, expanded: true))
        memory.remember(.init(preview: true, expanded: false), for: "<p>a</p>")
        #expect(memory.choice(for: "<p>a</p>") == .init(preview: true, expanded: false))
        #expect(memory.count == 2)
    }

    @Test func forgetsTheOldestPastItsLimit() {
        let memory = HtmlPreviewViewMemory()
        for index in 0...HtmlPreviewViewMemory.limit {
            memory.remember(.init(preview: false, expanded: false), for: "<p>\(index)</p>")
        }
        #expect(memory.count == HtmlPreviewViewMemory.limit)
        #expect(memory.choice(for: "<p>0</p>") == .init())
        #expect(memory.choice(for: "<p>\(HtmlPreviewViewMemory.limit)</p>").preview == false)
    }

    @Test func neverPinsAHugeSource() {
        let memory = HtmlPreviewViewMemory()
        let huge = String(repeating: "x", count: HtmlPreviewViewMemory.maxBytes)
        memory.remember(.init(preview: false, expanded: true), for: huge)
        #expect(memory.count == 0)
        #expect(memory.choice(for: huge) == .init())
    }
}
