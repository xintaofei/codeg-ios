import Foundation
import Testing
@testable import Codeg

// `MarkdownContent.parseBlocks`: task items, nested lists, image blocks, the
// fence `closed` flag — and the json-render spec-fence test
// (`src/lib/json-render/spec.test.ts` `isSpecStream`, codeg 0.44).

/// A block reduced to what the assertions read.
private enum B: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case list([Item])
    case quote(String)
    case code(String?, String, closed: Bool)
    case rule
    case table
    case image(MarkdownImageRef)
}

private struct Item: Equatable {
    let marker: String
    let level: Int
    let checked: Bool?
    let text: String
}

private func text(_ a: AttributedString) -> String { String(a.characters) }

@MainActor
private func parse(_ raw: String) -> [B] {
    MarkdownContent.parseBlocks(raw).map { block in
        switch block {
        case .paragraph(let a): return .paragraph(text(a))
        case .heading(let level, let a): return .heading(level, text(a))
        case .list(let items):
            return .list(items.map {
                Item(marker: MarkdownContent.markerText($0), level: $0.level,
                     checked: $0.checked, text: text($0.content))
            })
        case .quote(let parts): return .quote(parts.map(text).joined(separator: "\n"))
        case .code(let language, let code, let closed): return .code(language, code, closed: closed)
        case .rule: return .rule
        case .table: return .table
        case .image(let image): return .image(image)
        }
    }
}

private func image(_ alt: String, _ source: String, link: String? = nil, escape: Bool = false) -> B {
    .image(MarkdownImageRef(alt: alt, source: source, link: link, escapeInDestination: escape))
}

@MainActor
@Suite("task list items")
struct MarkdownTaskListTests {
    @Test func drawsUncheckedAndCheckedItemsInPlaceOfTheirBullets() {
        #expect(parse("- [ ] todo\n- [x] done\n- [X] Done too\n- plain") == [.list([
            Item(marker: "•", level: 0, checked: false, text: "todo"),
            Item(marker: "•", level: 0, checked: true, text: "done"),
            Item(marker: "•", level: 0, checked: true, text: "Done too"),
            Item(marker: "•", level: 0, checked: nil, text: "plain"),
        ])])
    }

    @Test func numberedItemsAreTasksToo() {
        #expect(parse("1. [ ] first\n2) [x] second") == [.list([
            Item(marker: "1.", level: 0, checked: false, text: "first"),
            Item(marker: "2.", level: 0, checked: true, text: "second"),
        ])])
    }

    @Test func needsTheSpaceAfterTheBox() {
        #expect(parse("- [ ]") == [.list([Item(marker: "•", level: 0, checked: nil, text: "[ ]")])])
        #expect(parse("- [x]done") == [.list([Item(marker: "•", level: 0, checked: nil, text: "[x]done")])])
        #expect(parse("- [y] maybe") == [.list([Item(marker: "•", level: 0, checked: nil, text: "[y] maybe")])])
        #expect(parse("-   [ ]   spaced") == [.list([Item(marker: "•", level: 0, checked: false, text: "spaced")])])
    }

    @Test func nestedTaskItemsKeepTheirDepth() {
        #expect(parse("- [ ] parent\n  - [x] child") == [.list([
            Item(marker: "•", level: 0, checked: false, text: "parent"),
            Item(marker: "◦", level: 1, checked: true, text: "child"),
        ])])
    }
}

@MainActor
@Suite("nested lists")
struct MarkdownNestedListTests {
    @Test func indentationSetsTheLevel() {
        #expect(parse("- a\n  - b\n    - c\n  - d\n- e") == [.list([
            Item(marker: "•", level: 0, checked: nil, text: "a"),
            Item(marker: "◦", level: 1, checked: nil, text: "b"),
            Item(marker: "•", level: 2, checked: nil, text: "c"),
            Item(marker: "◦", level: 1, checked: nil, text: "d"),
            Item(marker: "•", level: 0, checked: nil, text: "e"),
        ])])
    }

    @Test func fourSpaceStepsAndNestedKindsShareOneList() {
        #expect(parse("1. a\n    - b\n    - c\n2. d") == [.list([
            Item(marker: "1.", level: 0, checked: nil, text: "a"),
            Item(marker: "◦", level: 1, checked: nil, text: "b"),
            Item(marker: "◦", level: 1, checked: nil, text: "c"),
            Item(marker: "2.", level: 0, checked: nil, text: "d"),
        ])])
    }

    @Test func aTabIsOneStep() {
        #expect(parse("- a\n\t- b") == [.list([
            Item(marker: "•", level: 0, checked: nil, text: "a"),
            Item(marker: "◦", level: 1, checked: nil, text: "b"),
        ])])
    }

    @Test func depthIsCappedAtFour() {
        let raw = (0..<7).map { String(repeating: " ", count: $0 * 2) + "- l\($0)" }.joined(separator: "\n")
        guard case .list(let items) = parse(raw).first else { Issue.record("expected a list"); return }
        #expect(items.map(\.level) == [0, 1, 2, 3, 4, 4, 4])
    }

    @Test func anItemLeftOfTheFirstStaysAtTheTop() {
        #expect(parse("  - a\n- b") == [.list([
            Item(marker: "•", level: 0, checked: nil, text: "a"),
            Item(marker: "•", level: 0, checked: nil, text: "b"),
        ])])
    }

    @Test func aDedentLeftOfTheFirstItemRebasesTheTopLevel() {
        guard case .list(let items) = parse("  - a\n- b\n  - c").first else {
            Issue.record("expected a list"); return
        }
        #expect(items.map(\.level) == [0, 0, 1])
    }

    @Test func aDedentBetweenLevelsOpensASiblingLevel() {
        // Levels at 0 and 4; an item at 2 closes the 4 and nests under the 0.
        guard case .list(let items) = parse("- a\n    - b\n  - c").first else {
            Issue.record("expected a list"); return
        }
        #expect(items.map(\.level) == [0, 1, 1])
    }

    @Test func bulletsAndNumbersAtTheTopAreTwoLists() {
        #expect(parse("- a\n1. b") == [
            .list([Item(marker: "•", level: 0, checked: nil, text: "a")]),
            .list([Item(marker: "1.", level: 0, checked: nil, text: "b")]),
        ])
    }

    @Test func flatListsAreUnchanged() {
        #expect(parse("Intro\n- one\n- two\n\nAfter") == [
            .paragraph("Intro"),
            .list([
                Item(marker: "•", level: 0, checked: nil, text: "one"),
                Item(marker: "•", level: 0, checked: nil, text: "two"),
            ]),
            .paragraph("After"),
        ])
    }
}

@MainActor
@Suite("image blocks")
struct MarkdownImageBlockTests {
    @Test func aStandaloneImageIsItsOwnBlock() {
        #expect(parse("![shot](./shot.png)") == [image("shot", "./shot.png")])
    }

    @Test func anInlineImageSplitsItsParagraph() {
        #expect(parse("Before ![a](x.png) after") == [.paragraph("Before"), image("a", "x.png"), .paragraph("after")])
        #expect(parse("请扫码登录：\n\n![登录二维码](/tmp/qr.png)") == [.paragraph("请扫码登录："), image("登录二维码", "/tmp/qr.png")])
        #expect(parse("![a](1.png)![b](2.png)") == [image("a", "1.png"), image("b", "2.png")])
    }

    @Test func readsDestinationsAsCommonMarkDoes() {
        #expect(parse("![Preview](</repo/My Images/preview.png>)") == [image("Preview", "/repo/My Images/preview.png")])
        #expect(parse("![a](x.png \"Title\")") == [image("a", "x.png")])
        #expect(parse("![a](x_(1).png)") == [image("a", "x_(1).png")])
        #expect(parse("![](x.png)") == [image("", "x.png")])
        #expect(parse("![a](https://e.com/i.png?a=1&amp;b=2)") == [image("a", "https://e.com/i.png?a=1&b=2")])
        // A Windows path keeps its backslashes: `\r`, `\a` are no escapes.
        #expect(parse("![shot](C:\\repo\\a\\b.png)") == [image("shot", "C:\\repo\\a\\b.png")])
    }

    @Test func flagsAnEscapeThatMayHaveEatenASeparator() {
        #expect(parse("![shot](C:\\repo\\shots\\.preview.png)")
                == [image("shot", "C:\\repo\\shots.preview.png", escape: true)])
        #expect(parse("![shot](shots\\_preview.png)") == [image("shot", "shots_preview.png", escape: true)])
        // An escape in the label is not in the destination.
        #expect(parse("![a \\* b](./preview.png)") == [image("a * b", "./preview.png")])
    }

    @Test func aLinkedImageKeepsItsLink() {
        let linked = image("Preview", "./preview.png", link: "https://example.com/gallery")
        #expect(parse("[![Preview](./preview.png)](https://example.com/gallery)") == [linked])
        #expect(parse("[**![Preview](./preview.png)**](https://example.com/gallery)") == [linked])
    }

    @Test func aLinkWithOtherTextIsLeftAlone() {
        #expect(parse("[see ![a](b.png) here](https://x.y)").count == 1)
        guard case .paragraph = parse("[see ![a](b.png) here](https://x.y)").first else {
            Issue.record("expected a paragraph"); return
        }
    }

    @Test func doesNotInterpretExamplesInCode() {
        #expect(parse("Use `![a](x.png)` here") == [.paragraph("Use ![a](x.png) here")])
        #expect(parse("```md\n![Code](./code.png)\n```") == [.code("md", "![Code](./code.png)", closed: true)])
        guard case .paragraph = parse("\\![a](x.png)").first else {
            Issue.record("an escaped `!` is a link, not an image"); return
        }
    }

    @Test func aStreamingImageCountsOnceItsDestinationCloses() {
        #expect(parse("Look ![shot](./sh") == [.paragraph("Look ![shot](./sh")])
        #expect(parse("Look ![shot](./shot.png") == [.paragraph("Look ![shot](./shot.png")])
        #expect(parse("Look ![shot](./shot.png)") == [.paragraph("Look"), image("shot", "./shot.png")])
    }

    @Test func linkedFlag() {
        #expect(MarkdownImageRef(alt: "", source: "x", link: nil, escapeInDestination: false).linked == false)
        #expect(MarkdownImageRef(alt: "", source: "x", link: "h", escapeInDestination: false).linked)
    }
}

@MainActor
@Suite("code fences")
struct MarkdownFenceTests {
    @Test func aFenceIsClosedOnceItsClosingFenceArrives() {
        #expect(parse("```swift\nlet a = 1\n```") == [.code("swift", "let a = 1", closed: true)])
        #expect(parse("```swift\nlet a = 1") == [.code("swift", "let a = 1", closed: false)])
        #expect(parse("```swift") == [.code("swift", "", closed: false)])
        #expect(parse("~~~\na\n~~~") == [.code(nil, "a", closed: true)])
    }

    @Test func closesOnlyOnTheSameCharacterAtLeastAsLong() {
        #expect(parse("```\na\n~~~") == [.code(nil, "a\n~~~", closed: false)])
        #expect(parse("````md\n```js\nx\n```\n````\nafter")
                == [.code("md", "```js\nx\n```", closed: true), .paragraph("after")])
        #expect(parse("```\na\n``") == [.code(nil, "a\n``", closed: false)])
    }

    @Test func aFenceInAListItemLosesItsIndentation() {
        #expect(parse("1. Step\n   ```bash\n   npm i\n     nested\n   ```") == [
            .list([Item(marker: "1.", level: 0, checked: nil, text: "Step")]),
            .code("bash", "npm i\n  nested", closed: true),
        ])
    }

    @Test func backticksInTheInfoStringAreNotAFence() {
        #expect(parse("```inline``` text") == [.paragraph("inline text")])
    }
}

@Suite("isSpecStream")
struct SpecStreamTests {
    @Test func takesAFenceWhoseFirstLineIsAPatch() {
        let source = "\n\n" + #"{"op":"add","path":"/root","value":"main"}"# + "\n"
        #expect(MarkdownSpec.isSpecStream(source))
        #expect(MarkdownSpec.isSpecFence(language: "spec", code: source))
    }

    @Test func leavesAnRPMSpecFileAndAHalfWrittenFirstLineAsCode() {
        #expect(!MarkdownSpec.isSpecStream("Name: hello\nVersion: 1.0\n"))
        #expect(!MarkdownSpec.isSpecStream(#"{"op":"add","pa"#))
        #expect(!MarkdownSpec.isSpecStream(""))
    }

    @Test func aPatchHasATruthyOpAndAPath() {
        #expect(MarkdownSpec.isPatchLine(#"{"op":"replace","path":null}"#))
        #expect(!MarkdownSpec.isPatchLine(#"{"op":"","path":"/a"}"#))
        #expect(!MarkdownSpec.isPatchLine(#"{"op":false,"path":"/a"}"#))
        #expect(!MarkdownSpec.isPatchLine(#"{"path":"/a"}"#))
        #expect(!MarkdownSpec.isPatchLine(#"{"op":"add"}"#))
        #expect(!MarkdownSpec.isPatchLine(#"["op","path"]"#))
    }

    @Test func onlyAFenceLabelledSpec() {
        let patch = #"{"op":"add","path":"/root","value":"main"}"#
        #expect(MarkdownSpec.isSpecFence(language: "spec title=x", code: patch))
        #expect(!MarkdownSpec.isSpecFence(language: "json", code: patch))
        #expect(!MarkdownSpec.isSpecFence(language: "SPEC", code: patch))
        #expect(!MarkdownSpec.isSpecFence(language: nil, code: patch))
    }
}
