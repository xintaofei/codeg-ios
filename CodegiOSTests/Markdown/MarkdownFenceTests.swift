import Foundation
import Testing
@testable import Codeg

// `MarkdownFence`: which renderer a fenced block goes to, and when its source
// is final. The language match is the web's `mermaidSourceFromPre`
// (`mermaid-view.test.ts`): `language-mermaid` exactly.

@Suite("Mermaid fence language")
struct MermaidFenceLanguageTests {
    @Test func claimsAMermaidFenceByItsLanguage() {
        #expect(MarkdownFence.isMermaid(language: "mermaid"))
        // The language is the info string's first word.
        #expect(MarkdownFence.isMermaid(language: "mermaid title=flow"))
        #expect(MarkdownFence.isMermaid(language: "mermaid\textra"))
    }

    @Test func doesNotClaimALookAlikeLanguage() {
        #expect(!MarkdownFence.isMermaid(language: "mermaidx"))
        #expect(!MarkdownFence.isMermaid(language: "mermaid-lite"))
        #expect(!MarkdownFence.isMermaid(language: "ts"))
        #expect(!MarkdownFence.isMermaid(language: "Mermaid"))
        #expect(!MarkdownFence.isMermaid(language: nil))
        #expect(!MarkdownFence.isMermaid(language: ""))
    }

    @Test func leavesPlantUmlAsCode() {
        for language in ["plantuml", "puml"] {
            #expect(MarkdownFence.kind(language: language, code: "@startuml\nA -> B\n@enduml", closed: true,
                                       settled: true, assistantReply: true) == .code)
        }
    }
}

@Suite("fence settling")
struct FenceSettlingTests {
    @Test func everyFenceIsFinalOnceTheTextStopsStreaming() {
        #expect(MarkdownFence.isSettled(closed: true, streaming: false, isLastBlock: true, sourceEndsWithNewline: false))
        // A reply that ended mid-fence: its fence never closes, and is final.
        #expect(MarkdownFence.isSettled(closed: false, streaming: false, isLastBlock: true, sourceEndsWithNewline: false))
    }

    @Test func anOpenFenceIsNotFinalWhileStreaming() {
        #expect(!MarkdownFence.isSettled(closed: false, streaming: true, isLastBlock: true, sourceEndsWithNewline: true))
        #expect(!MarkdownFence.isSettled(closed: false, streaming: true, isLastBlock: false, sourceEndsWithNewline: true))
    }

    @Test func aClosingLineStillArrivingIsNotFinal() {
        // "```" received, its line not ended: it may yet be "````" or "```js".
        #expect(!MarkdownFence.isSettled(closed: true, streaming: true, isLastBlock: true, sourceEndsWithNewline: false))
        #expect(MarkdownFence.isSettled(closed: true, streaming: true, isLastBlock: true, sourceEndsWithNewline: true))
    }

    @Test func aClosedFenceWithTextAfterItIsFinal() {
        #expect(MarkdownFence.isSettled(closed: true, streaming: true, isLastBlock: false, sourceEndsWithNewline: false))
    }
}

@Suite("fence routing")
struct FenceRoutingTests {
    @Test func drawsADiagramInAnyMarkdown() {
        for reply in [true, false] {
            #expect(MarkdownFence.kind(language: "mermaid", code: "graph TD;", closed: true, settled: true,
                                       assistantReply: reply) == .mermaid(ready: true))
        }
    }

    @Test func holdsAStreamingDiagramUntilItsSourceIsFinal() {
        #expect(MarkdownFence.kind(language: "mermaid", code: "graph TD;\nA-->", closed: false, settled: false,
                                   assistantReply: true) == .mermaid(ready: false))
    }

    @Test func claimsASpecFenceOnlyInAnAssistantReply() {
        let spec = #"{"op":"add","path":"/root","value":"main"}"#
        #expect(MarkdownFence.kind(language: "spec", code: spec, closed: true, settled: true,
                                   assistantReply: true) == .spec)
        #expect(MarkdownFence.kind(language: "spec", code: spec, closed: true, settled: true,
                                   assistantReply: false) == .code)
    }

    @Test func leavesOtherFencesAsCode() {
        #expect(MarkdownFence.kind(language: "swift", code: "let x = 1", closed: true, settled: true,
                                   assistantReply: true) == .code)
        #expect(MarkdownFence.kind(language: nil, code: "plain", closed: true, settled: true,
                                   assistantReply: true) == .code)
    }
}

@MainActor
@Suite("diagram fences in parsed Markdown")
struct DiagramFenceParsingTests {
    private func fences(_ raw: String) -> [(String?, String, Bool)] {
        MarkdownContent.parseBlocks(raw).compactMap { block in
            if case .code(let language, let code, let closed) = block { return (language, code, closed) }
            return nil
        }
    }

    @Test func readsABacktickOrTildeMermaidFence() {
        for raw in ["```mermaid\ngraph TD;\nA-->B;\n```", "~~~mermaid\ngraph TD;\nA-->B;\n~~~"] {
            let found = fences(raw)
            #expect(found.count == 1)
            #expect(found.first?.0 == "mermaid")
            #expect(found.first?.1 == "graph TD;\nA-->B;")
            #expect(found.first?.2 == true)
            #expect(MarkdownFence.isMermaid(language: found.first?.0))
        }
    }

    @Test func aFenceStillArrivingIsOpen() {
        let found = fences("Here:\n\n```mermaid\ngraph TD;\nA-->")
        #expect(found.count == 1)
        #expect(found.first?.2 == false)
    }
}
