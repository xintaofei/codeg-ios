import Foundation
import Testing
@testable import Codeg

/// The wire form of `@` mentions: web `reference-text.test.ts`,
/// `src/lib/reference-link.test.ts` and `suggestion/adapters.test.ts` where
/// they apply, plus the iOS token ⇄ link round trip.
@Suite struct ComposerReferenceEscapingTests {
    typealias Codec = ComposerReferenceCodec

    @Test func linkTextEscapesEveryInlineSignificantCharacter() {
        #expect(Codec.escapeMarkdownText("a](http://evil) x") == #"a\]\(http://evil\) x"#)
        #expect(Codec.escapeMarkdownText("a`b") == #"a\`b"#)
        #expect(Codec.escapeMarkdownText(#"\*_~<>"#) == #"\\\*\_\~\<\>"#)
        #expect(Codec.escapeMarkdownText("请看 README") == "请看 README")
    }

    @Test func aDestinationIsAngleWrappedOnlyWhenItMustBe() {
        #expect(Codec.escapeLinkDestination("file:///repo/app.ts") == "file:///repo/app.ts")
        #expect(Codec.escapeLinkDestination("file:///a/b (1).ts") == "<file:///a/b (1).ts>")
        // "\" -> "\\" and ">" -> "\>": a literal `\>` cannot close the link early.
        #expect(Codec.escapeLinkDestination(#"file:///a/\> x"#) == #"<file:///a/\\\> x>"#)
        #expect(Codec.escapeLinkDestination("file:///a\r\n/b") == "file:///a/b")
    }

    @Test func aLabelStaysOneInlineToken() {
        #expect(Codec.collapseNewlines("line1\nline2") == "line1 line2")
        #expect(Codec.collapseNewlines("a  \r\n  b") == "a b")
        #expect(Codec.collapseNewlines("a  b") == "a  b", "a run without a break is kept")
    }

    @Test func referencesSerializeLikeTheWeb() {
        let file = ComposerReference(token: "@app.ts", kind: .file, label: "app.ts", uri: "file:///repo/app.ts")
        #expect(file.markdown == "[app.ts](file:///repo/app.ts)")
        let agent = ComposerReference.agent(.codex, label: "Codex")
        #expect(agent.markdown == "[@Codex](codeg://agent/codex)")
        let crafted = ComposerReference(token: "@x", kind: .agent, label: "Rev](x) [y", uri: "codeg://agent/x")
        #expect(crafted.markdown == #"[@Rev\]\(x\) \[y](codeg://agent/x)"#)
        let multiline = ComposerReference(token: "@x", kind: .agent, label: "line1\nline2", uri: "codeg://agent/x")
        #expect(multiline.markdown == "[@line1 line2](codeg://agent/x)")
    }

    @Test func aFileMentionJoinsTheRootAndTheRelativePath() {
        let item = ComposerReference.file(name: "app.ts", relativePath: "src/app.ts", workspaceRoot: "/repo")
        #expect(item.token == "@src/app.ts")
        #expect(item.label == "app.ts")
        #expect(item.uri == "file:///repo/src/app.ts")
        #expect(ComposerReference.file(name: "app.ts", relativePath: "src/app.ts", workspaceRoot: "/repo/").uri
                == "file:///repo/src/app.ts")
    }

    @Test func anAgentMentionCarriesItsRoutingURI() {
        let item = ComposerReference.agent(.claudeCode, label: "Claude Code")
        #expect(item.token == "@Claude Code")
        #expect(item.uri == "codeg://agent/claude_code")
        #expect(item.markdown == "[@Claude Code](codeg://agent/claude_code)")
    }
}

/// Web `buildFileUri` / `encodeURIComponent`.
@Suite struct FileURITests {
    typealias Codec = ComposerReferenceCodec

    @Test func posixPath() {
        #expect(Codec.buildFileUri("/repo/src/app.ts") == "file:///repo/src/app.ts")
    }

    @Test func windowsPathNormalizesSlashesAndEncodesTheDrive() {
        #expect(Codec.buildFileUri(#"C:\repo\app.ts"#) == "file:///C%3A/repo/app.ts")
    }

    @Test func segmentsArePercentEncodedButSeparatorsAreNot() {
        #expect(Codec.buildFileUri("/a/b c#d?e.ts") == "file:///a/b%20c%23d%3Fe.ts")
        #expect(Codec.buildFileUri("/a/说明 (1).md") == "file:///a/%E8%AF%B4%E6%98%8E%20(1).md")
    }

    @Test func uncPathsTakeTheAuthorityForm() {
        #expect(Codec.buildFileUri("//server/share/doc.md") == "file://server/share/doc.md")
        #expect(Codec.buildFileUri(#"\\server\share\doc.md"#) == "file://server/share/doc.md")
    }

    @Test func verbatimPrefixesAreStripped() {
        #expect(Codec.buildFileUri(#"\\?\C:\Users\song\uploads\img.png"#) == "file:///C%3A/Users/song/uploads/img.png")
        #expect(Codec.buildFileUri(#"\\?\UNC\server\share\doc.md"#) == "file://server/share/doc.md")
        #expect(Codec.buildFileUri(#"\\?\unc\server\share\doc.md"#) == "file://server/share/doc.md")
        #expect(Codec.buildFileUri(#"\\?\Volume{7b2f1c40}\img.png"#) == "file://%3F/Volume%7B7b2f1c40%7D/img.png")
    }

    @Test func encodeURIComponentKeepsOnlyTheUnreservedSet() {
        #expect(Codec.encodeURIComponent("AZaz09-_.!~*'()") == "AZaz09-_.!~*'()")
        #expect(Codec.encodeURIComponent("a b/c%") == "a%20b%2Fc%25")
        #expect(Codec.encodeURIComponent("中") == "%E4%B8%AD")
        #expect(Codec.encodeURIComponent("😀") == "%F0%9F%98%80")
    }
}

/// Web `reference-link.test.ts`: the link tokenizer and its unescapers.
@Suite struct ReferenceLinkTokenizerTests {
    typealias Codec = ComposerReferenceCodec

    @Test func unescapesTheLabel() {
        #expect(Codec.unescapeReferenceLabel(#"a\]b\(c"#) == "a]b(c")
        #expect(Codec.unescapeReferenceLabel(#"Screenshot \(1\).png"#) == "Screenshot (1).png")
        #expect(Codec.unescapeReferenceLabel("plain name.ts") == "plain name.ts")
    }

    @Test func unwrapsTheDestination() {
        #expect(Codec.unwrapReferenceDestination("file:///x/foo.ts") == "file:///x/foo.ts")
        #expect(Codec.unwrapReferenceDestination("  codeg://session/42  ") == "codeg://session/42")
        #expect(Codec.unwrapReferenceDestination(#"file:///x\y"#) == #"file:///x\y"#)
        #expect(Codec.unwrapReferenceDestination("<file:///x/a b.ts>") == "file:///x/a b.ts")
        #expect(Codec.unwrapReferenceDestination(#"<file:///C:\\repo\\app.ts>"#) == #"file:///C:\repo\app.ts"#)
        #expect(Codec.unwrapReferenceDestination(#"<file:///x/a\<b\>c.ts>"#) == "file:///x/a<b>c.ts")
    }

    @Test func splitsProseAroundALink() {
        #expect(Codec.tokenizeReferenceLinks("look at [foo.ts](file:///x/foo.ts) here") == [
            .text("look at "),
            .link(raw: "[foo.ts](file:///x/foo.ts)", label: "foo.ts", destination: "file:///x/foo.ts"),
            .text(" here"),
        ])
    }

    @Test func keepsTheAngleBracketsOfAWrappedDestination() {
        #expect(Codec.tokenizeReferenceLinks("[a b.ts](<file:///x/a b.ts>)") == [
            .link(raw: "[a b.ts](<file:///x/a b.ts>)", label: "a b.ts", destination: "<file:///x/a b.ts>"),
        ])
    }

    @Test func emptyDestinationsAndEmptyLabels() {
        #expect(Codec.tokenizeReferenceLinks("[a]()") == [.link(raw: "[a]()", label: "a", destination: "")])
        #expect(Codec.tokenizeReferenceLinks("[](x)") == [.text("[](x)")])
    }

    @Test func aStrayBracketDoesNotHideALaterLink() {
        let tokens = Codec.tokenizeReferenceLinks("text [oops [x](file:///y)")
        #expect(tokens == [.text("text [oops "), .link(raw: "[x](file:///y)", label: "x", destination: "file:///y")])
    }

    @Test func foldsLinksToTheirLabels() {
        #expect(Codec.foldLinks("[README.md](file:///repo/README.md) fix the bug") == "README.md fix the bug")
        #expect(Codec.foldLinks(#"ask [@Codex](codeg://agent/codex) about [a \(1\)](<file:///r/a (1)>)"#)
                == "ask @Codex about a (1)")
    }
}

/// The field shows tokens; the prompt carries links. Encoding and decoding
/// must round-trip, and a token the user edited must fall back to plain text.
@Suite struct ComposerReferenceCodecTests {
    typealias Codec = ComposerReferenceCodec

    private let root = "/repo"
    private var app: ComposerReference {
        .file(name: "app.ts", relativePath: "src/app.ts", workspaceRoot: root)
    }
    private var codex: ComposerReference { .agent(.codex, label: "Codex") }

    @Test func encodesRegisteredTokens() {
        #expect(Codec.encode("look at @src/app.ts please", references: [app])
                == "look at [app.ts](file:///repo/src/app.ts) please")
        #expect(Codec.encode("@Codex review @src/app.ts", references: [app, codex])
                == "[@Codex](codeg://agent/codex) review [app.ts](file:///repo/src/app.ts)")
    }

    @Test func encodesNextToCJKText() {
        #expect(Codec.encode("请看@src/app.ts谢谢", references: [app])
                == "请看[app.ts](file:///repo/src/app.ts)谢谢")
        #expect(Codec.encode("让@Codex，帮我", references: [codex])
                == "让[@Codex](codeg://agent/codex)，帮我")
    }

    @Test func anEditedTokenGoesOutAsPlainText() {
        #expect(Codec.encode("@src/app.tsx", references: [app]) == "@src/app.tsx")
        #expect(Codec.encode("@src/app.ts.bak", references: [app]) == "@src/app.ts.bak")
        #expect(Codec.encode("@src/app", references: [app]) == "@src/app")
        #expect(Codec.encode("x@src/app.ts", references: [app]) == "x@src/app.ts", "glued to a word: an email, not a mention")
        #expect(Codec.encode("@Codexx", references: [codex]) == "@Codexx")
    }

    @Test func aSentenceEndAndClosingPunctuationStillEndTheToken() {
        #expect(Codec.encode("see @src/app.ts.", references: [app]) == "see [app.ts](file:///repo/src/app.ts).")
        #expect(Codec.encode("(@src/app.ts)", references: [app]) == "(@src/app.ts)", "`(` cannot start a mention")
        #expect(Codec.encode("@src/app.ts, ok", references: [app]) == "[app.ts](file:///repo/src/app.ts), ok")
    }

    @Test func theLongerTokenWins() {
        let dir = ComposerReference.file(name: "src", relativePath: "src", workspaceRoot: root)
        #expect(Codec.encode("@src/app.ts and @src", references: [dir, app])
                == "[app.ts](file:///repo/src/app.ts) and [src](file:///repo/src)")
    }

    @Test func nothingRegisteredLeavesTheTextAlone() {
        #expect(Codec.encode("@src/app.ts", references: []) == "@src/app.ts")
    }

    private func assertRoundTrip(_ text: String, _ references: [ComposerReference]) {
        let wire = Codec.encode(text, references: references)
        #expect(wire != text, "nothing was encoded in \(text)")
        let decoded = Codec.decode(wire, workspaceRoot: root)
        #expect(decoded.text == text)
        #expect(Codec.encode(decoded.text, references: decoded.references) == wire)
    }

    @Test func roundTripsPlainMentions() {
        assertRoundTrip("look at @src/app.ts please", [app])
        assertRoundTrip("@Codex review @src/app.ts", [app, codex])
    }

    @Test func roundTripsSpacesAndParentheses() {
        let odd = ComposerReference.file(name: "my file (1).md", relativePath: "docs/my file (1).md", workspaceRoot: root)
        #expect(odd.uri == "file:///repo/docs/my%20file%20(1).md")
        #expect(odd.markdown == #"[my file \(1\).md](<file:///repo/docs/my%20file%20(1).md>)"#)
        assertRoundTrip("open @docs/my file (1).md now", [odd])
    }

    @Test func roundTripsCJK() {
        let doc = ComposerReference.file(name: "说明.md", relativePath: "文档/说明.md", workspaceRoot: root)
        assertRoundTrip("请看@文档/说明.md，谢谢", [doc])
        let agent = ComposerReference.agent(.claudeCode, label: "克劳德")
        assertRoundTrip("让@克劳德 处理", [agent])
    }

    @Test func decodeKeepsWhatTheComposerDidNotProduce() {
        let outside = "[x.md](file:///elsewhere/x.md)"
        #expect(Codec.decode(outside, workspaceRoot: root).text == outside)
        #expect(Codec.decode(outside, workspaceRoot: root).references.isEmpty)
        let session = "[Login](codeg://session/123)"
        #expect(Codec.decode(session, workspaceRoot: root).text == session)
        let web = "[docs](https://example.com)"
        #expect(Codec.decode(web, workspaceRoot: nil).text == web)
        let fileWithoutRoot = "[app.ts](file:///repo/src/app.ts)"
        #expect(Codec.decode(fileWithoutRoot, workspaceRoot: nil).text == fileWithoutRoot)
    }

    @Test func decodeKeepsALinkItsTokenWouldNotSurvive() {
        // Glued to the word before: `see@src/app.ts` would not encode back.
        let glued = "see[app.ts](file:///repo/src/app.ts)"
        #expect(Codec.decode(glued, workspaceRoot: root).text == glued)
        // Two links back to back: `@a@b` would not either.
        let adjacent = "[a](file:///repo/a)[b](file:///repo/b)"
        #expect(Codec.decode(adjacent, workspaceRoot: root).text == adjacent)
        // Followed by more of a name.
        let continued = "[app.ts](file:///repo/src/app.ts)x"
        #expect(Codec.decode(continued, workspaceRoot: root).text == continued)
    }

    @Test func decodeFoldsAgentLinksAndStripsTheirAt() {
        let decoded = Codec.decode("ask [@Codex](codeg://agent/codex) now", workspaceRoot: nil)
        #expect(decoded.text == "ask @Codex now")
        #expect(decoded.references == [ComposerReference(token: "@Codex", kind: .agent, label: "Codex",
                                                          uri: "codeg://agent/codex")])
    }

    @Test func relativePathRequiresTheExactURITheBuilderMakes() {
        #expect(Codec.relativePath(ofFileURI: "file:///repo/src/app.ts", under: "/repo") == "src/app.ts")
        #expect(Codec.relativePath(ofFileURI: "file:///repo/src/app.ts", under: "/repo/") == "src/app.ts")
        #expect(Codec.relativePath(ofFileURI: "file:///repo2/app.ts", under: "/repo") == nil)
        #expect(Codec.relativePath(ofFileURI: "file:///repo/a.ts#L10", under: "/repo") == nil)
        #expect(Codec.relativePath(ofFileURI: "file:///repo/a%20b.ts", under: "/repo") == "a b.ts")
    }
}
