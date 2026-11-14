import Foundation
import Testing
@testable import Codeg

// `ChatHtmlDocument`: the chat HTML preview's sanitizer and document builder.
// Cases ported from the web's `chat-html-document.test.ts` and
// `html-preview-inline.test.ts` (the wrapper / head / body / CSP cases; the
// resource-inlining ones don't apply — the chat inlines nothing). The web
// asserts on a parsed DOM; these assert on the markup, which is kept as
// written.

private let theme = ChatHtmlTheme(dark: true, accent: .neutral)

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// The normalized document's head and body content: from its `<head>` to the
/// first `</head>` after it, and from the `<body>` after that to the last
/// `</body>` (author raw text may hold either end tag).
private func parts(_ html: String) -> (head: String, body: String) {
    guard let headStart = html.range(of: "<head"),
          let headOpenEnd = html.range(of: ">", range: headStart.upperBound..<html.endIndex),
          let headEnd = html.range(of: "</head>", range: headOpenEnd.upperBound..<html.endIndex),
          let bodyStart = html.range(of: "<body", range: headEnd.upperBound..<html.endIndex),
          let bodyOpenEnd = html.range(of: ">", range: bodyStart.upperBound..<html.endIndex),
          let bodyEnd = html.range(of: "</body>", options: .backwards) else { return ("", "") }
    return (String(html[headOpenEnd.upperBound..<headEnd.lowerBound]),
            String(html[bodyOpenEnd.upperBound..<bodyEnd.lowerBound]))
}

@Suite("chat HTML document isolation")
struct ChatHtmlDocumentBuildTests {
    @Test func keepsCSSSvgAndDocumentAttributesAndStripsScriptsHandlersEmbedsAndRedirects() {
        let doc = ChatHtmlDocument.build(
            source: #"<html lang="zh" class="theme"><head><meta http-equiv="refresh" content="0;url=https://example.com"><base href="https://example.com"><style>.x{display:flex}</style></head><body class="cards" onload="attack()"><div onclick="attack()"><script>attack()</script><iframe srcdoc="attack"></iframe><a href="javascript:attack()">A</a><svg><path d="M0 0" /></svg></div></body></html>"#,
            theme: theme)
        #expect(doc.contains(#"lang="zh""#))
        #expect(doc.contains(#"class="cards""#))
        #expect(doc.contains(".x{display:flex}"))
        #expect(doc.contains("<svg>"))
        #expect(!doc.contains("attack"))
        #expect(!doc.contains("https://example.com"))
        // No script at all: this client runs none (no nonce'd size reporter).
        #expect(!doc.contains("<script"))
        #expect(doc.contains("script-src 'none'"))
        #expect(!doc.contains("'unsafe-eval'"))
        // The author's <base> is gone; the pinned one is the only one.
        #expect(occurrences(of: "<base", in: doc) == 1)
    }

    @Test func putsTheThemeBeforeAuthorCSSAndIsNotMisledByFakeEndTagsInCSS() throws {
        let doc = ChatHtmlDocument.build(
            source: #"<div><style>.x::before{content:"</head></body>"}body{margin:20px}</style><p>A</p></div>"#,
            theme: theme)
        let themeAt = try #require(doc.range(of: "--viz-series-1:var(--blue)"))
        let authorAt = try #require(doc.range(of: #".x::before{content:"</head></body>"}body{margin:20px}"#))
        #expect(themeAt.lowerBound < authorAt.lowerBound)
        // The theme sits in the real head, the author's style in the body.
        let (head, body) = parts(doc)
        #expect(head.contains("--viz-series-1"))
        #expect(body.contains(#"content:"</head></body>""#))
        #expect(body.contains("<p>A</p>"))
    }

    @Test func stripsSvgXlinkHrefAndAnimatedLinksButKeepsReferencesIntoTheDocument() {
        let doc = ChatHtmlDocument.build(
            source: ##"<svg xmlns:xlink="http://www.w3.org/1999/xlink"><defs><linearGradient id="g"/><path id="p" d="M0 0"/></defs><a xlink:href="https://attack.example/x"><text>A</text></a><a><set attributeName="href" to="https://attack.example/y"/><animate attributeName="xlink:href" values="https://attack.example/z"/><text>B</text></a><use href="#p"/><use xlink:href="#p"/><rect fill="url(#g)"/></svg><a href="#top">Top</a>"##,
            theme: theme)
        #expect(!doc.contains("attack.example"))
        #expect(!doc.contains("<set"))
        #expect(!doc.contains("<animate"))
        #expect(doc.contains(##"<use href="#p""##))
        #expect(doc.contains(##"<use xlink:href="#p""##))
        #expect(doc.contains(##"<a href="#top">"##))
        #expect(doc.contains(#"fill="url(#g)""#))
    }

    @Test func addsTheViewportLastInTheHeadSoItWinsOverTheAuthors() throws {
        let doc = ChatHtmlDocument.build(
            source: #"<html><head><meta name="viewport" content="width=1200"></head><body><p>x</p></body></html>"#,
            theme: theme)
        let (head, _) = parts(doc)
        let author = try #require(head.range(of: #"content="width=1200""#))
        let ours = try #require(head.range(of: ChatHtmlDocument.viewportMeta))
        #expect(author.lowerBound < ours.lowerBound)
    }

    @Test func themesTheSurfaceAndTheColorScheme() {
        let dark = ChatHtmlDocument.build(source: "<p>x</p>", theme: theme)
        #expect(dark.contains(":root{color-scheme:dark}"))
        #expect(dark.contains("html{background:\(RichBlockPalette(dark: true).css)"))
        let light = ChatHtmlDocument.build(source: "<p>x</p>", theme: ChatHtmlTheme(dark: false, accent: .orange))
        #expect(light.contains(":root{color-scheme:light}"))
        #expect(light.contains("#1a1c1f"))
    }
}

@Suite("active content stripping")
struct ChatHtmlStripTests {
    private func strip(_ html: String) -> String { ChatHtmlDocument.inlineStripped(html) }

    @Test func stripsAuthorSuppliedCSPMeta() {
        let out = strip(#"<head><meta http-equiv="Content-Security-Policy" content="default-src *"></head><body></body>"#)
        #expect(!out.contains("default-src *"))
    }

    @Test func doesNotThrowOnMalformedInput() {
        let out = strip(#"<<<x>>> <img src="missing.png">"#)
        #expect(out.contains("missing.png"))
    }

    @Test func removesEveryActiveElementWithItsContent() {
        let out = strip(#"<p>a</p><object data="x.swf"><param name="p" value="v"><em>fallback</em></object><embed src="y"><link rel="stylesheet" href="z.css"><template><b>t</b></template><script src="s.js"></script><iframe src="https://e.example"></iframe><p>b</p>"#)
        for gone in ["<object", "fallback", "<param", "<embed", "<link", "<template", "<b>t</b>", "<script", "<iframe", "e.example"] {
            #expect(!out.contains(gone), "\(gone)")
        }
        #expect(out.contains("<p>a</p>"))
        #expect(out.contains("<p>b</p>"))
    }

    @Test func removesFormTargetsNoncesAndEveryHandler() {
        let out = strip(#"<form action="https://e.example/post"><button formaction="https://e.example/b" ONCLICK="x()" onmouseover=y()>Go</button></form><style nonce="n1">p{}</style>"#)
        #expect(!out.contains("e.example"))
        #expect(!out.lowercased().contains("onclick"))
        #expect(!out.contains("onmouseover"))
        #expect(!out.contains("nonce"))
        #expect(out.contains("<form>"))
        #expect(out.contains("<button>Go</button>"))
    }

    @Test func judgesALinkByItsDecodedValue() {
        // "&#35;" is "#": a fragment, kept as written.
        let kept = strip(#"<a href="&#35;notes">N</a>"#)
        #expect(kept.contains(#"<a href="&#35;notes">"#))
        // "&#106;" is "j": still a javascript: link.
        let removed = strip(#"<a href="&#106;avascript:x()">J</a>"#)
        #expect(!removed.contains("avascript"))
        #expect(removed.contains("<a>J</a>"))
    }

    @Test func removesAMetaRefreshAndBaseButKeepsOtherMeta() {
        let out = strip(#"<head><meta charset="utf-8"><meta http-equiv=" Refresh " content="0;url=https://e.example"><base href="https://e.example/"></head><body>x</body>"#)
        #expect(out.contains(#"<meta charset="utf-8">"#))
        #expect(!out.contains("e.example"))
        #expect(!out.contains("<base"))
    }

    @Test func preservesHtmlAndBodyWrapperAttributes() {
        let out = strip(#"<html lang="en"><head></head><body class="preview" data-theme="dark"><p>x</p></body></html>"#)
        #expect(out.contains(#"<html lang="en">"#))
        #expect(out.contains(#"<body class="preview" data-theme="dark">"#))
    }

    @Test func ignoresCommentedOutAndStringLiteralWrapperTagsWhenExtractingAttrs() {
        let out = strip(
            #"<!-- <body class="wrong" onload="evil()"> -->"# +
            #"<html lang="en"><head><style>p::after{content:"<body class=fake>"}</style></head>"# +
            #"<body class="preview" data-theme="dark"></body></html>"#)
        // The real body's attributes — not the commented-out tag's, nor the
        // one in the CSS string (which, as text, stays where it was).
        #expect(out.contains("</head>\n" + #"<body class="preview" data-theme="dark">"#))
    }

    @Test func doesNotTruncateWrapperAttrsContainingAGreaterThanInAQuotedValue() {
        let out = strip(#"<html><body data-x="a>b" class="c"></body></html>"#)
        #expect(out.contains(#"<body data-x="a>b" class="c">"#))
    }

    @Test func keepsHeadMetadataInTheHeadAndContentInTheBody() {
        let out = strip(#"<html><head><meta name="viewport" content="w=1"><title>T</title></head><body class="x"><p>hi</p></body></html>"#)
        let (head, body) = parts(out)
        #expect(head.contains(#"<meta name="viewport" content="w=1">"#))
        #expect(head.contains("<title>T</title>"))
        #expect(body.contains("<p>hi</p>"))
        #expect(out.contains(#"<body class="x">"#))
    }

    @Test func keepsBodyLeadingMetadataInTheBody() {
        // The web case uses a <script>, which this mode removes; a <style>
        // shows the same split.
        let out = strip(#"<html><head><title>T</title></head><body><style>p{}</style><p>hi</p></body></html>"#)
        let (head, body) = parts(out)
        #expect(head.contains("<title>T</title>"))
        #expect(!head.contains("<style>"))
        #expect(body.contains("<style>p{}</style><p>hi</p>"))
    }

    @Test func splitsADocumentWithoutABodyAfterItsLeadingMetadata() {
        let out = strip("\n<!-- c --><style>.a{}</style>\n<meta name=\"x\" content=\"y\"><div>A</div><style>.b{}</style>")
        let (head, body) = parts(out)
        #expect(head.contains("<style>.a{}</style>"))
        #expect(head.contains(#"<meta name="x" content="y">"#))
        #expect(body.hasPrefix("<div>A</div>"))
        #expect(body.contains("<style>.b{}</style>"))
    }

    @Test func ignoresWrapperTagsInsideRCDATATitleContent() {
        let out = strip(#"<html><head><title><body class="fake"></title></head><body class="real"><p>x</p></body></html>"#)
        #expect(out.contains(#"<body class="real">"#))
        #expect(out.contains(#"<title><body class="fake"></title>"#))
    }

    @Test func ignoresWrapperTagsInsideTemplateContent() {
        let out = strip(#"<html><head><template><body class="fake"></template></head><body class="real"><p>x</p></body></html>"#)
        #expect(out.contains(#"<body class="real">"#))
        #expect(!out.contains("fake"))
    }

    @Test func doesNotEndATemplateSkipAtAnEndTagInsideAComment() {
        let out = strip(#"<html><head><template><!-- </template> --><body class="fake"></body></template></head><body class="real"><p>x</p></body></html>"#)
        #expect(out.contains(#"<body class="real">"#))
        #expect(!out.contains("fake"))
    }
}

@Suite("sandbox CSP")
struct ChatHtmlSandboxTests {
    private let base = "<html><head></head><body>x</body></html>"

    @Test func blocksScriptsAndNetwork() {
        let out = ChatHtmlDocument.withSandboxCsp(base)
        #expect(out.contains(#"http-equiv="Content-Security-Policy""#))
        #expect(out.contains("default-src 'none'"))
        #expect(out.contains("script-src 'none'"))
        #expect(out.contains("form-action 'none'"))
        #expect(out.contains("frame-src 'none'"))
        #expect(!out.contains("connect-src"))
        #expect(ChatHtmlDocument.strictCSP == "default-src 'none'; img-src data: blob:; media-src data: blob:; style-src 'unsafe-inline' data:; font-src data:; script-src 'none'; form-action 'none'; base-uri about:; frame-src 'none'")
    }

    @Test func insertsTheCSPMetaAsTheFirstHeadChild() {
        #expect(ChatHtmlDocument.withSandboxCsp(base).contains(#"<head><meta http-equiv="Content-Security-Policy""#))
    }

    @Test func injectsCorrectlyWhenTheHeadHasAnAttributeContainingAGreaterThan() {
        let out = ChatHtmlDocument.withSandboxCsp(#"<html><head data-x="a>b"></head><body></body></html>"#)
        #expect(out.contains(#"<head data-x="a>b"><meta http-equiv="Content-Security-Policy""#))
    }

    @Test func targetsTheRealHeadNotOneInsideAnAttributeValue() {
        let out = ChatHtmlDocument.withSandboxCsp(#"<html data-x="<head >"><head></head><body></body></html>"#)
        #expect(occurrences(of: "Content-Security-Policy", in: out) == 1)
        #expect(out.contains(#"<head><meta http-equiv="Content-Security-Policy""#))
        #expect(out.contains(#"data-x="<head >""#))
    }

    @Test func ignoresAFakeScriptEndAndAHeadInsideScriptText() throws {
        let out = ChatHtmlDocument.withSandboxCsp(
            #"<html><script>var s = "</scriptx><head></head>";</script><head></head><body></body></html>"#)
        #expect(occurrences(of: "Content-Security-Policy", in: out) == 1)
        let scriptEnd = try #require(out.range(of: "</script>"))
        let csp = try #require(out.range(of: "Content-Security-Policy"))
        #expect(scriptEnd.lowerBound < csp.lowerBound)
    }

    @Test func pinsTheBaseURLSoFragmentLinksStayInTheDocument() {
        let out = ChatHtmlDocument.withSandboxCsp(base)
        #expect(out.contains(#"<base href="about:srcdoc">"#))
        #expect(out.contains("base-uri about:"))
        #expect(!out.contains("base-uri 'none'"))
    }

    @Test func emitsTheCSPMetaBeforeTheBase() throws {
        let out = ChatHtmlDocument.withSandboxCsp(base)
        let meta = try #require(out.range(of: #"http-equiv="Content-Security-Policy""#))
        let pinned = try #require(out.range(of: #"<base href="about:srcdoc">"#))
        #expect(meta.lowerBound < pinned.lowerBound)
    }

    @Test func makesTheInjectedBaseTheOnlyOne() {
        #expect(occurrences(of: "<base", in: ChatHtmlDocument.withSandboxCsp(base)) == 1)
    }

    @Test func addsAHeadWhenThereIsNone() {
        #expect(ChatHtmlDocument.withHtmlPreviewHead("<html><p>x</p></html>", "<i></i>")
                == "<html><head><i></i></head><p>x</p></html>")
        #expect(ChatHtmlDocument.withHtmlPreviewHead("<p>x</p>", "<i></i>") == "<head><i></i></head><p>x</p>")
    }
}

@Suite("HTML tokenizer")
struct HtmlTokenizerTests {
    private func tags(_ html: String) -> [String] {
        HtmlTokenizer.tokenize(Array(html.utf8)).compactMap { token in
            if case .startTag(let tag) = token { return tag.name }
            return nil
        }
    }

    @Test func endsCommentsTheWayTheHtmlTokenizerDoes() {
        // "<!-->" and "<!--->" are complete (empty) comments; "--!>" ends one.
        #expect(tags("<!--><b>1</b>") == ["b"])
        #expect(tags("<!---><i>2</i>") == ["i"])
        #expect(tags("<!-- x --!><u>3</u>") == ["u"])
        #expect(tags("<!-- <s>never</s>") == [])
    }

    @Test func keepsRawTextUntilItsOwnEndTag() {
        #expect(tags("<script>a = '</scriptx><b>'</script><i>") == ["script", "i"])
        #expect(tags("<style>p::after{content:'<em>'}</style>") == ["style"])
        #expect(tags("<textarea><b>x</b></textarea>") == ["textarea"])
    }

    @Test func dropsATagTheInputEndsInside() {
        #expect(tags(#"<p>x</p><a href="unterminated"#) == ["p"])
    }

    @Test func readsAttributesQuotedUnquotedAndBare() throws {
        let tokens = HtmlTokenizer.tokenize(Array(#"<input type=checkbox checked data-x='a"b' value = "1"/>"#.utf8))
        guard case .startTag(let tag) = try #require(tokens.first) else {
            Issue.record("not a start tag")
            return
        }
        #expect(tag.name == "input")
        #expect(tag.attributes.map(\.name) == ["type", "checked", "data-x", "value"])
        #expect(tag.attributes[1].valueRange == nil)
        #expect(tag.selfClosing)
    }

    @Test func treatsASlashAsAnAttributeSeparator() throws {
        let tokens = HtmlTokenizer.tokenize(Array("<div/onclick=x>".utf8))
        guard case .startTag(let tag) = try #require(tokens.first) else {
            Issue.record("not a start tag")
            return
        }
        #expect(tag.attributes.map(\.name) == ["onclick"])
        #expect(!tag.selfClosing)
    }

    @Test func lowercasesNamesAndCountsBogusCommentsAsComments() {
        #expect(tags("<DIV><Svg>") == ["div", "svg"])
        #expect(tags("<?xml version='1.0'?><!x><p>") == ["p"])
    }
}

@Suite("HTML entities")
struct HtmlEntitiesTests {
    @Test func decodesNumericAndCommonNamedReferences() {
        #expect(HtmlEntities.decode("&#35;top") == "#top")
        #expect(HtmlEntities.decode("&#x23;top") == "#top")
        #expect(HtmlEntities.decode("a&amp;b&lt;c&gt;") == "a&b<c>")
        #expect(HtmlEntities.decode("java&#115;cript&colon;") == "javascript:")
    }

    @Test func leavesWhatItDoesNotKnow() {
        #expect(HtmlEntities.decode("&bogus; & plain") == "&bogus; & plain")
        #expect(HtmlEntities.decode("no references") == "no references")
    }
}
