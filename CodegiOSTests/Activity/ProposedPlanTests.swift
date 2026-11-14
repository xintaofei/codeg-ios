import Foundation
import Testing
@testable import Codeg

/// codex Plan-mode `<proposed_plan>` extraction — port of the web's
/// `adaptMessageTurn proposed plan` suite (`ai-elements-adapter.test.ts`,
/// codeg 0.44). The web runs the rule inside `adaptMessageTurn`; here `wrap`
/// is the pure function with the adapter's fall-through (nil → the text
/// verbatim), and the adapter itself is exercised by the suites below.
struct ProposedPlanTests {
    private typealias Segment = ProposedPlan.Segment

    private func wrap(_ text: String, _ streaming: Bool = false) -> [Segment] {
        ProposedPlan.extract(text, isStreaming: streaming) ?? [.text(text)]
    }

    private func types(_ segments: [Segment]) -> [String] {
        segments.map {
            switch $0 {
            case .text: return "text"
            case .plan: return "proposed-plan"
            }
        }
    }

    private func rendered(_ segments: [Segment]) -> String {
        segments.map {
            switch $0 {
            case .text(let text): return text
            case .plan(let markdown, _): return markdown
            }
        }.joined(separator: "|")
    }

    @Test func liftsAClosedBlockIntoACardWithSurroundingProse() {
        let adapted = wrap("Here is my plan.\n<proposed_plan>\n# Plan\n\n- step one\n</proposed_plan>\nProceeding.")
        #expect(types(adapted) == ["text", "proposed-plan", "text"])
        guard case .plan(let markdown, let streaming) = adapted[1] else {
            Issue.record("expected a plan"); return
        }
        #expect(streaming == false)
        #expect(markdown.contains("# Plan"))
        #expect(markdown.contains("- step one"))
        // The raw tags never leak into rendered content.
        #expect(!rendered(adapted).contains("<proposed_plan>"))
    }

    @Test func rendersAnUnclosedBlockAsAStreamingCardWhileTheTurnStreams() {
        let adapted = wrap("<proposed_plan>\n# Draft", true)
        #expect(types(adapted) == ["proposed-plan"])
        guard case .plan(_, let streaming) = adapted[0] else { Issue.record("expected a plan"); return }
        #expect(streaming == true)
    }

    @Test func leavesOrdinaryAssistantTextUntouched() {
        #expect(ProposedPlan.extract("Just a normal reply.", isStreaming: false) == nil)
        #expect(types(wrap("Just a normal reply.")) == ["text"])
    }

    // Regression: any agent may write *about* the tag. Verbatim from a Claude
    // Code reply that explained this very parser — the unclosed mention inside a
    // code span used to swallow the rest of the sentence into a plan card.
    @Test func keepsATagQuotedInAnInlineCodeSpanAsPlainText() {
        let text = "**缺陷 A — 计划卡片**。新增 `event_msg.item_completed` 分支，"
            + "并把助手的 `<proposed_plan>` 记录从 promotion 闸门前拦下来单独处理。"
        #expect(wrap(text) == [.text(text)])
    }

    @Test func keepsAQuotedOpenClosePairInsideOneCodeSpanAsPlainText() {
        let text = "| **2** | `<proposed_plan>…</proposed_plan>` ← 计划回来了 |"
        #expect(wrap(text) == [.text(text)])
    }

    @Test func keepsSeveralQuotedMentionsInOneBlockAsPlainText() {
        let text = "| 助手正文落在哪 | `item_completed`(14) + `<proposed_plan>`(15) | 正常 |\n"
            + "解析器两份都不要：`<proposed_plan>` 撞上 promotion 闸门。"
        #expect(wrap(text) == [.text(text)])
    }

    @Test func keepsTagsInsideAFencedCodeBlockAsPlainText() {
        let text = "codex writes the record like this:\n\n"
            + "```text\n<proposed_plan>\n# Plan\n</proposed_plan>\n```\n\nThat is all."
        #expect(wrap(text) == [.text(text)])
    }

    // Mid-stream the closing backtick has not arrived, so the code-span check
    // cannot see the quote yet; the opener is still mid-line, which is what
    // stops a half-typed sentence from flashing a plan card.
    @Test func keepsAHalfTypedQuoteAsPlainTextWhileTheTurnStreams() {
        #expect(types(wrap("并把助手的 `<proposed_plan>", true)) == ["text"])
    }

    @Test func ignoresAnIndentedTagMarkdownWouldRenderAsCode() {
        #expect(types(wrap("Example:\n\n    <proposed_plan>\n    # Plan")) == ["text"])
    }

    // A tab reaches CommonMark's four-column indent on its own.
    @Test func ignoresATabIndentedTag() {
        #expect(types(wrap("Example:\n\n\t<proposed_plan>\n\t# Plan")) == ["text"])
    }

    // A CRLF line slice ends in `\r`, which JS `.` never matches — leaving it in
    // makes every fence unrecognisable and silently disables the code-block
    // guard on Windows-style text.
    @Test func keepsTagsInsideACRLFFencedCodeBlockAsPlainText() {
        let text = "before\r\n```text\r\n<proposed_plan>\r\n# Plan\r\n"
            + "</proposed_plan>\r\n```\r\nafter"
        #expect(wrap(text) == [.text(text)])
    }

    @Test func stillLiftsARealPlanFromCRLFText() {
        let adapted = wrap("Here is my plan.\r\n<proposed_plan>\r\n# Plan\r\n\r\n- step one\r\n"
            + "</proposed_plan>\r\nProceeding.")
        #expect(types(adapted) == ["text", "proposed-plan", "text"])
        #expect(adapted[1] == .plan(markdown: "# Plan\r\n\r\n- step one", streaming: false))
    }

    @Test func stillLiftsARealPlanFromABlockThatAlsoQuotesTheTag() {
        let adapted = wrap("The `<proposed_plan>` tag wraps it.\n"
            + "<proposed_plan>\n# Plan\n\n- step one\n</proposed_plan>\nProceeding.")
        #expect(types(adapted) == ["text", "proposed-plan", "text"])
        #expect(adapted[0] == .text("The `<proposed_plan>` tag wraps it.\n"))
        #expect(adapted[1] == .plan(markdown: "# Plan\n\n- step one", streaming: false))
    }

    @Test func closesOnTheRealTagNotOneQuotedInsideThePlanBody() {
        let adapted = wrap("<proposed_plan>\n# Plan\n\n```text\n</proposed_plan>\n```\n"
            + "</proposed_plan>\nProceeding.")
        #expect(types(adapted) == ["proposed-plan", "text"])
        #expect(adapted[0] == .plan(markdown: "# Plan\n\n```text\n</proposed_plan>\n```", streaming: false))
        #expect(adapted[1] == .text("\nProceeding."))
    }

    // MARK: iOS additions — the rest of the web's branches, pinned

    @Test func anUnclosedBlockOnceSettledIsAPlainCardOfTheRest() {
        #expect(wrap("Intro\n<proposed_plan>\n# Truncated") ==
                [.text("Intro\n"), .plan(markdown: "# Truncated", streaming: false)])
    }

    @Test func anEmptyBlockStillConsumesItsTags() {
        // Settled: no card, no text — the tags never render.
        #expect(ProposedPlan.extract("<proposed_plan>\n</proposed_plan>", isStreaming: false) == [])
        #expect(ProposedPlan.extract("<proposed_plan>", isStreaming: false) == [])
        // Streaming: an opened block shows its (empty) card.
        #expect(ProposedPlan.extract("<proposed_plan>", isStreaming: true) == [.plan(markdown: "", streaming: true)])
        // A CLOSED empty block is never a streaming card, even mid-stream.
        #expect(ProposedPlan.extract("<proposed_plan></proposed_plan>", isStreaming: true) == [])
    }

    @Test func everyBlockInOneTextBecomesACard() {
        let adapted = wrap("<proposed_plan>\nA\n</proposed_plan>\nbetween\n<proposed_plan>\nB\n</proposed_plan>")
        #expect(adapted == [.plan(markdown: "A", streaming: false), .text("\nbetween\n"),
                            .plan(markdown: "B", streaming: false)])
    }

    @Test func aMidLineOpenerIsSkippedButALaterLineStartOneLifts() {
        let adapted = wrap("say <proposed_plan> here\n<proposed_plan>\nP\n</proposed_plan>")
        #expect(adapted == [.text("say <proposed_plan> here\n"), .plan(markdown: "P", streaming: false)])
    }

    @Test func upToThreeSpacesOfIndentStillOpens() {
        #expect(types(wrap("   <proposed_plan>\nP\n</proposed_plan>")) == ["proposed-plan"])
    }

    @Test func anUnclosedFenceHidesEverythingAfterIt() {
        let text = "```\ncode\n<proposed_plan>\nP\n</proposed_plan>"
        #expect(wrap(text) == [.text(text)])
    }

    @Test func aTildeFenceIsNotClosedByBackticks() {
        let text = "~~~\n```\n<proposed_plan>\nP\n</proposed_plan>\n~~~"
        #expect(wrap(text) == [.text(text)])
    }

    @Test func aFenceLineWithTrailingTextDoesNotClose() {
        // "``` x" is not a closer, so the fence runs on and the tag stays code.
        let text = "```\n``` x\n<proposed_plan>\nP\n</proposed_plan>"
        #expect(wrap(text) == [.text(text)])
    }

    @Test func theTagSearchIsByCodeUnitNotGrapheme() {
        // A combining mark after `>` forms one grapheme with it; JS still finds
        // the tag, and so must this.
        #expect(ProposedPlan.containsOpenTag("<proposed_plan>\u{301}"))
        #expect(!ProposedPlan.containsOpenTag("<<proposed_pla>"))
        #expect(ProposedPlan.containsOpenTag("<<proposed_plan>"))
    }
}

/// Where the lifted plan lands in a reply: the adapter and the activity model.
@MainActor
struct ProposedPlanPlacementTests {
    private let date = Date(timeIntervalSince1970: 1_792_000_000)

    private func turn(_ id: String, _ blocks: [ContentBlock]) -> MessageTurn {
        MessageTurn(id: id, role: .assistant, blocks: blocks, timestamp: date)
    }

    private func kinds(_ parts: [RenderPart]) -> [String] {
        parts.map {
            switch $0 {
            case .text: return "text"
            case .proposedPlan: return "proposed-plan"
            case .tool: return "tool"
            default: return "other"
            }
        }
    }

    private static let read: [ContentBlock] = [
        .toolUse(id: "r1", name: "Read", inputPreview: #"{"file_path":"/r/a.ts"}"#, status: .unknown, meta: nil),
        .toolResult(id: "r1", outputPreview: "x", isError: false, agentStats: nil),
    ]

    // web: "carries a reloaded codex plan turn: plan card, then its approval marker"
    @Test func aReloadedCodexPlanTurnIsPlanThenProseThenTheReview() {
        let parts = MessageRender.adaptTurn(turn("codex-plan-reload", [
            .text("<proposed_plan>\n# 演示计划\n\n- step one\n</proposed_plan>\n\n如果你希望调整，告诉我。"),
            .toolUse(id: "codex-plan-review-3", name: "plan_review", inputPreview: nil, status: .unknown, meta: nil),
            .toolResult(id: "codex-plan-review-3", outputPreview: "User approved the plan.", isError: false, agentStats: nil),
        ]))
        #expect(kinds(parts) == ["proposed-plan", "text", "tool"])
        guard case .proposedPlan(let markdown, let streaming) = parts[0] else {
            Issue.record("expected a proposed plan"); return
        }
        #expect(markdown == "# 演示计划\n\n- step one")
        #expect(streaming == false)
        if case .text(let prose) = parts[1] { #expect(!prose.contains("<proposed_plan>")) }
        if case .tool(let vm) = parts[2] {
            #expect(vm.rawName == "plan_review")
            #expect(vm.state == .done)
        }
    }

    @Test func aPlanAfterTheLastCallIsTheAnswer() {
        let parts = MessageRender.adaptTurn(turn("a", Self.read + [
            .text("Read it.\n<proposed_plan>\n# P\n</proposed_plan>\nShall I go ahead?"),
        ]))
        let model = BuildActivity.build(parts, isStreaming: false)
        #expect(kinds(model.answer) == ["text", "proposed-plan", "text"])
        #expect(model.steps.count == 1)
        #expect(BuildActivity.hasVisibleAnswer(model.answer))
    }

    @Test func aPlanBeforeMoreWorkStaysANoteInTheProcess() {
        let parts = MessageRender.adaptTurn(turn("a", [
            .text("<proposed_plan>\n# P\n</proposed_plan>"),
        ] + Self.read))
        let model = BuildActivity.build(parts, isStreaming: false)
        #expect(model.answer.isEmpty)
        guard case .note(let key, .proposedPlan(let markdown, false))? = model.steps.first else {
            Issue.record("the plan is the reply's first step"); return
        }
        #expect(key.hasPrefix("note:"))
        #expect(markdown == "# P")
    }

    @Test func anUnclosedBlockStreamsOnlyInTheRunningRound() {
        let blocks: [ContentBlock] = [.text("<proposed_plan>\n# Draft")]
        let settled = MessageRender.adaptTurn(turn("a", blocks), liveness: .settled)
        let running = MessageRender.adaptTurn(turn("a", blocks), liveness: .round)
        guard case .proposedPlan(_, let settledStreaming)? = settled.first,
              case .proposedPlan(_, let runningStreaming)? = running.first else {
            Issue.record("both lift the block"); return
        }
        #expect(settledStreaming == false)
        #expect(runningStreaming == true)
    }

    @Test func aSettledReplyDrawsThePlanAsItsOwnNode() {
        let turns = [
            MessageTurn(id: "u", role: .user, blocks: [.text("plan it")], timestamp: date),
            turn("a", Self.read + [.text("<proposed_plan>\n# P\n</proposed_plan>")]),
        ]
        let nodes = TranscriptTimeline.buildPersisted(turns: turns, pending: [], agent: .codex,
                                                       suppressInFlight: false)
        let plan = nodes.first { if case .proposedPlan = $0.content { return true }; return false }
        guard let plan, case .proposedPlan(let markdown, let streaming) = plan.content else {
            Issue.record("the plan is a node"); return
        }
        #expect(markdown == "# P")
        #expect(streaming == false)
        #expect(plan.reply?.role == .always, "the trailing plan is the answer, kept when the reply folds")
        if case .plan = plan.marker {} else { Issue.record("the plan node wears the plan marker") }
        #expect(!nodes.contains { if case .assistantText(let s) = $0.content { return s.contains("proposed_plan") }; return false })
    }

    /// The live builder never reads a run's text: a run holding a plan block is
    /// still one `liveText` node, split by its leaf view.
    @Test func aLiveRunIsLeftWholeForItsLeafToSplit() {
        let live = LiveTurn()
        live.appendText("<proposed_plan>\n# Draft")
        let nodes = TranscriptTimeline.buildLive(live, agent: .codex)
        #expect(nodes.contains { if case .liveText = $0.content { return true }; return false })
        #expect(!nodes.contains { if case .proposedPlan = $0.content { return true }; return false })
    }

    /// Once the live reply is folded into history it takes the persisted path.
    @Test func aSnapshottedLiveReplyLiftsThePlan() throws {
        let live = LiveTurn()
        live.appendText("<proposed_plan>\n# Done\n</proposed_plan>")
        live.isStreaming = false
        let turn = try #require(live.snapshotAsMessageTurns().first)
        let parts = MessageRender.adaptTurn(turn)
        #expect(kinds(parts) == ["proposed-plan"])
    }
}
