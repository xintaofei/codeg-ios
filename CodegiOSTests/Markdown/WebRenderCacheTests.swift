import CoreGraphics
import Foundation
import Testing
@testable import Codeg

// The off-screen renderer's cache keys (content + theme + size, never a turn
// id) and its bounded text cache.

@Suite("web render cache keys")
struct WebRenderKeyTests {
    private let dark = MermaidTheme(dark: true)
    private let light = MermaidTheme(dark: false)

    @Test func theSameSourceAndThemeShareAKey() {
        #expect(WebRenderKey.mermaid(source: "graph TD;\nA-->B;", theme: dark)
                == WebRenderKey.mermaid(source: "graph TD;\nA-->B;", theme: dark))
    }

    @Test func theThemeIsPartOfTheKey() {
        #expect(WebRenderKey.mermaid(source: "graph TD;", theme: dark)
                != WebRenderKey.mermaid(source: "graph TD;", theme: light))
        #expect(dark.name == "dark")
        #expect(light.name == "default")
    }

    @Test func anyChangeToTheSourceChangesTheKey() {
        #expect(WebRenderKey.mermaid(source: "graph TD;", theme: dark)
                != WebRenderKey.mermaid(source: "graph TD; ", theme: dark))
    }

    @Test func theKeyStaysSmallForALongSource() {
        let long = String(repeating: "A-->B;\n", count: 10_000)
        #expect(WebRenderKey.mermaid(source: long, theme: dark).utf8.count < 100)
    }

    @Test func aPictureKeyAddsItsWidthAndHeightCap() {
        let a = WebRenderKey.mermaidImage(source: "graph TD;", theme: dark, width: 343, clip: 500)
        #expect(a.hasPrefix(WebRenderKey.mermaid(source: "graph TD;", theme: dark)))
        #expect(a != WebRenderKey.mermaidImage(source: "graph TD;", theme: dark, width: 360, clip: 500))
        #expect(a != WebRenderKey.mermaidImage(source: "graph TD;", theme: dark, width: 343, clip: 420))
        // A sub-point wobble in the measured column is the same picture.
        #expect(a == WebRenderKey.mermaidImage(source: "graph TD;", theme: dark, width: 343.2, clip: 500))
    }

    @Test func roundsToWholePoints() {
        #expect(WebRenderKey.points(343.4) == 343)
        #expect(WebRenderKey.points(343.6) == 344)
        #expect(WebRenderKey.points(0) == 0)
        #expect(WebRenderKey.points(.nan) == 0)
    }

    @Test func theDigestIsSHA256() {
        #expect(WebRenderKey.digest("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@MainActor
@Suite("text result cache")
struct TextResultCacheTests {
    private func cache(limit: Int = 3, maxBytes: Int = 1 << 20) -> TextResultCache<String> {
        TextResultCache<String>(limit: limit, maxBytes: maxBytes) { $0.utf16.count * 2 }
    }

    @Test func evictsTheLeastRecentlyUsedPastItsEntryLimit() {
        let c = cache(limit: 2)
        c.insert("a", for: "1")
        c.insert("b", for: "2")
        _ = c["1"]
        c.insert("c", for: "3")
        #expect(c["1"] == "a")
        #expect(c["2"] == nil)
        #expect(c["3"] == "c")
        #expect(c.count == 2)
    }

    @Test func evictsPastItsByteBudget() {
        let c = cache(limit: 10, maxBytes: 1000)
        c.insert(String(repeating: "x", count: 200), for: "big1")
        c.insert(String(repeating: "y", count: 200), for: "big2")
        c.insert(String(repeating: "z", count: 200), for: "big3")
        #expect(c.totalBytes <= 1000)
        #expect(c["big1"] == nil)
        #expect(c["big3"] != nil)
    }

    @Test func keepsTheNewestEntryEvenWhenItAloneIsOverBudget() {
        let c = cache(limit: 10, maxBytes: 100)
        c.insert("small", for: "a")
        c.insert(String(repeating: "x", count: 500), for: "huge")
        #expect(c["huge"] != nil)
        #expect(c["a"] == nil)
    }

    @Test func replacingAnEntryReleasesItsBytes() {
        let c = cache()
        c.insert(String(repeating: "x", count: 100), for: "k")
        let first = c.totalBytes
        c.insert("y", for: "k")
        #expect(c.totalBytes < first)
        #expect(c.count == 1)
        c.removeAll()
        #expect(c.totalBytes == 0)
    }
}
