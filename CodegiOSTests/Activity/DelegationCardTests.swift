import Foundation
import Testing
@testable import Codeg

// `src/lib/delegation-card.test.ts` (codeg 0.44): the `parseInput` wrapper
// cases iOS shares, `isRefusedResume` and its two "resume verdicts" suites,
// and "opencode code-mode execute payloads", case for case. Suites map to the
// web's `describe` blocks and tests to its `it`s. Each `code` is the RUNTIME
// value of the web's JS literal (its `\\n` is a backslash and an `n`, its
// `\u2028` the character); `JSON.stringify({ code })` is `payload(_:)`.
//
// iOS has no `errorText` channel — an error result rides in `output` with
// `isError` — so the web's `(output, errorText)` pairs are passed as such to
// the `output:errorText:` entry points.
//
// `isAffirmedResume`'s halves of the verdict suites are in
// `DelegationBindingTests`. Not ported: the `console.warn` spy
// of "reads an unreadable call quietly" (iOS logs nothing; the parse it makes
// is pinned by "screens unknowable argument syntax out of the parse").

private typealias D = DelegationModel
private typealias C = CodeModeDelegation

/// `JSON.stringify({ code })`.
private func payload(_ code: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["code": code], options: [.withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

private func isInput(_ code: String) -> Bool { C.isCodeModeDelegationInput(payload(code)) }
private func parse(_ code: String) -> DelegationParsedInput { D.parseInput(payload(code)) }
private func agent(_ wire: String) -> AgentType? { AgentType(rawValue: wire) }
private let empty = DelegationParsedInput()

/// `JSON.stringify(object)` for a report.
private func json(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

@Suite("parseInput wrapper peeling")
struct DelegationParseInputTests {
    @Test func readsTopLevelDelegationArgs() {
        let parsed = D.parseInput(#"{"agent_type":"codex","task":"run the build","working_dir":"/tmp/proj"}"#)
        #expect(parsed.agentType == .codex)
        #expect(parsed.task == "run the build")
        #expect(parsed.workingDir == "/tmp/proj")
    }

    // Skipped: "peels Cursor's MCP args wrapper" — iOS's shared argument
    // walker (`CompanionDetect.unwrapArgs`) does not peel `args` yet.

    @Test func returnsEmptyForUndelegationLikePayloads() {
        let parsed = D.parseInput(#"{"command":"ls -la"}"#)
        #expect(parsed.agentType == nil)
        #expect(parsed.task == nil)
    }

    /// The web's `ALL_AGENT_TYPES` at codeg 0.44.
    static let allAgentTypes = [
        "claude_code", "codex", "open_code", "gemini", "open_claw", "cline", "hermes",
        "code_buddy", "kimi_code", "minimax_code", "pi", "grok", "cursor", "deepseek",
        "qoder", "antigravity", "kiro", "zcode", "trae", "command_code",
    ]

    @Test("recognizes the agent_type", arguments: allAgentTypes)
    func recognizesTheAgentType(_ agentType: String) {
        let parsed = D.parseInput(json(["agent_type": agentType, "task": "do the thing"]))
        #expect(parsed.agentType?.rawValue == agentType)
    }

    // iOS addition: `coerceAgentType` narrows what `AgentType(rawValue:)`
    // alone would accept — an unknown slug is no agent, a custom one is.
    @Test func narrowsTheAgentSlugTheWayTheWebDoes() {
        #expect(D.parseInput(#"{"agent_type":"nope","task":"t"}"#).agentType == nil)
        #expect(D.parseInput(#"{"agent_type":" codex ","task":"t"}"#).agentType == .codex)
        #expect(D.parseInput(#"{"agent_type":"custom:my-agent","task":"t"}"#).agentType?.rawValue == "custom:my-agent")
        #expect(D.parseInput(#"{"assistant_id":"7"}"#).assistantId == 7)
        #expect(D.parseInput(#"{"assistant_id":true,"task":"t"}"#).assistantId == nil)
        #expect(D.parseInput(#"{"assistant_id":"07","task":"t"}"#).assistantId == nil)
    }
}

@Suite("isRefusedResume")
struct RefusedResumeTests {
    // `not_resumable_report` (broker.rs) reports the task's REAL status, so a
    // refusal and a genuine resume differ only by `error_code`.
    @Test("recognizes a refusal reported with status", arguments: ["completed", "running", "canceled"])
    func recognizesARefusalReportedWithStatus(_ status: String) {
        #expect(D.isRefusedResume(output: json([
            "task_id": "t-1", "status": status, "error_code": "not_resumable", "agent_type": "codex",
            "child_conversation_id": 9, "message": "Not resumed: the task already completed.",
        ]), errorText: nil))
    }

    @Test func leavesAGenuineResumeAckAlone() {
        #expect(!D.isRefusedResume(output: json([
            "task_id": "t-1", "status": "running", "agent_type": "codex",
            "child_conversation_id": 9, "message": "Delegation resumed.",
        ]), errorText: nil))
    }

    // An unknown task id is refused too, but by a report that names no agent
    // and no child — nothing for a card to draw.
    @Test func doesNotClaimAnUnknownTaskReport() {
        #expect(!D.isRefusedResume(output: json(["task_id": "t-1", "status": "unknown", "message": "Unknown task id"]),
                                   errorText: nil))
        #expect(!D.isRefusedResume(output: nil, errorText: nil))
    }

    @Test func readsARefusalDeliveredAsAnError() {
        #expect(D.isRefusedResume(output: nil, errorText: json([
            "task_id": "t-1", "status": "failed", "error_code": "not_resumable",
        ])))
    }
}

// `render_task_report` keeps the whole report in `structuredContent` and
// renders only `message` as content text; OpenCode drops `structuredContent`
// wholesale, so on those hosts the prefix is the only signal left.
@Suite("resume verdicts on hosts that drop structuredContent")
struct ResumeVerdictTextTests {
    static let refusalText =
        "Not resumed: the task already completed — resume only applies to a canceled task."
    static let ackText =
        "Delegation resumed. task_id=t-1 (unchanged). Call get_delegation_status with this id."

    @Test func stillRecognizesARefusalFromTheMessageTextAlone() {
        #expect(D.isRefusedResume(output: Self.refusalText, errorText: nil))
    }

    // (Skipped: "affirms a resume from the ack text alone" and "does not affirm
    // an unknown-task report or a refusal" — `isAffirmedResume`.)

    @Test func keepsTheStructuredVerdictAuthoritativeWhenItSurvived() {
        let structured = json([
            "task_id": "t-1", "status": "running", "agent_type": "codex",
            "child_conversation_id": 9, "message": Self.ackText,
        ])
        #expect(!D.isRefusedResume(output: structured, errorText: nil))
    }

    // iOS addition: the prefix is read after JS `trimStart`, and only as a
    // prefix of code units.
    @Test func readsThePrefixAfterLeadingWhitespaceOnly() {
        #expect(D.isRefusedResume(output: "\u{FEFF}\n  " + Self.refusalText, errorText: nil))
        #expect(!D.isRefusedResume(output: "not resumed: lower case", errorText: nil))
        #expect(!D.isRefusedResume(output: "Note: Not resumed: quoted", errorText: nil))
    }
}

// For a `completed` report `render_task_report` renders `text` in preference
// to `message`, and a resume whose child finished during setup reports the
// child's OWN output there. A sub-agent that merely talks about delegation must
// not be read as a verdict about its own card.
@Suite("resume verdicts never read a child's prose as a verdict")
struct ResumeVerdictChildProseTests {
    static let childProse =
        "I reviewed the resume path. The broker answers `Not resumed: <why>` when it "
        + "refuses, and `Delegation resumed. task_id=…` when it succeeds."

    @Test func ignoresBothMarkersWhenTheyAppearInsideACompletedChildsText() {
        let structured = json([
            "task_id": "t-1", "status": "completed", "agent_type": "codex",
            "child_conversation_id": 9, "text": Self.childProse,
        ])
        #expect(!D.isRefusedResume(output: structured, errorText: nil))
    }

    @Test func ignoresThemInBareChildTextOnAStructureDroppingHost() {
        #expect(!D.isRefusedResume(output: Self.childProse, errorText: nil))
    }

    // (Skipped: "does not affirm a structured report that named no child" —
    // `isAffirmedResume`.)

    // The legacy synchronous `{kind: "ok"|"err"}` shape is a RECOGNIZED report
    // too, so it must never fall through to the text path.
    @Test func treatsTheLegacyKindShapedOutcomeAsStructured() {
        let legacyOk = json([
            "kind": "ok", "child_conversation_id": 9,
            "text": "Not resumed: is the phrase the broker uses when it declines.",
        ])
        #expect(!D.isRefusedResume(output: legacyOk, errorText: nil))
        let legacyErr = json([
            "kind": "err", "code": "spawn_failed",
            "message": "Delegation resumed is the phrase used on success.",
        ])
        #expect(!D.isRefusedResume(output: legacyErr, errorText: nil))
    }
}

// iOS: what a refused resume's card says.
@MainActor
@Suite("the refused resume's card")
struct ResumeRefusalCardTests {
    private func resume(_ output: String, isError: Bool = false, name: String = "mcp__codeg-mcp__resume_delegation") -> ToolCallVM {
        ToolCallVM(id: "r1", rawName: name, kind: "", state: isError ? .error : .done,
                   input: #"{"task_id":"b0858712-9257-45a1-850e-c80e75291939","reason":"killed"}"#,
                   output: output, content: nil, isError: isError)
    }

    @Test func statesTheBrokersReasonAndTheTask() {
        let refusal = D.resumeRefusal(resume(json([
            "task_id": "b0858712-9257-45a1-850e-c80e75291939", "status": "completed",
            "error_code": "not_resumable", "agent_type": "codex", "child_conversation_id": 9,
            "message": "Not resumed: the task already completed — resume only applies to a canceled task.",
        ])))
        #expect(refusal == ResumeRefusal(
            taskId: "b0858712-9257-45a1-850e-c80e75291939",
            message: "Not resumed: the task already completed — resume only applies to a canceled task."))
    }

    @Test func prefersTheRefusalOverTheChildsTextAHostShows() {
        let output = json([
            "content": [["type": "text", "text": "The child's earlier answer."]],
            "structuredContent": [
                "task_id": "t-1", "status": "completed", "error_code": "not_resumable",
                "text": "The child's earlier answer.", "message": "Not resumed: the task already completed.",
            ],
        ])
        #expect(D.resumeRefusal(resume(output))?.message == "Not resumed: the task already completed.")
    }

    @Test func readsTheTextAHostKept() {
        #expect(D.resumeRefusal(resume("Not resumed: the task is still running."))?.message
                == "Not resumed: the task is still running.")
        #expect(D.resumeRefusal(resume(#"{"task_id":"t-1","status":"failed","error_code":"not_resumable"}"#,
                                       isError: true)) != nil)
    }

    @Test func leavesEveryOtherCallAlone() {
        #expect(D.resumeRefusal(resume(json([
            "task_id": "t-1", "status": "running", "agent_type": "codex", "child_conversation_id": 9,
            "message": "Delegation resumed.",
        ]))) == nil)
        #expect(D.resumeRefusal(resume("Not resumed: quoted by another tool", name: "Bash")) == nil)
        #expect(D.resumeRefusal(resume("")) == nil)
    }
}

// opencode 2.x code-mode: MCP calls execute as JS source inside the built-in
// `execute` tool, arriving as raw_input `{"code": "…delegate_to_agent({…})…"}`.
@Suite("opencode code-mode execute payloads")
struct CodeModeDelegationPayloadTests {
    // A real opencode emission: bracketed accessor, working_dir, template task
    // with escaped newline/tab, CJK text. The `\n`/`\t` are JS SOURCE escapes;
    // the runtime cooks them to a real newline/tab, which the card must show.
    static let opencodeCall =
        #"await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", working_dir: "/tmp/对拍", task: `review 对拍\nsecond\tline ✓` })"#

    @Test func recognizesAndParsesTheOpencodeEmission() {
        #expect(isInput(Self.opencodeCall))
        let parsed = parse(Self.opencodeCall)
        #expect(parsed.agentType == .codex)
        #expect(parsed.task == "review 对拍\nsecond\tline ✓")
        #expect(parsed.workingDir == "/tmp/对拍")
        #expect(parsed.assistantId == nil)
    }

    @Test func parsesAnLSPSBearingEmissionVerbatimLikeTheMCPSide() {
        // U+2028/U+2029 pass through BOTH sides verbatim (ECMA-262 normalizes
        // only CR/CRLF).
        let code = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `seg"#
            + "\u{2028}a\u{2029}b" + #"` })"#
        #expect(isInput(code))
        let parsed = parse(code)
        #expect(parsed.agentType == .codex)
        #expect(parsed.task == "seg\u{2028}a\u{2029}b")
    }

    @Test func parsesTheNamespacedAccessorFormWithWorkingDir() {
        let code = #"await tools.codeg_mcp.delegate_to_agent({ agent_type: 'codex', task: 'ship it', working_dir: "/tmp/proj" })"#
        #expect(isInput(code))
        let parsed = parse(code)
        #expect(parsed.agentType == .codex)
        #expect(parsed.task == "ship it")
        #expect(parsed.workingDir == "/tmp/proj")
    }

    @Test func unescapesTheMinimalJSEscapeSetInTemplateTasks() {
        let code = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: `a\nb\tc\u4e2d\u{1F600}` })"#
        #expect(parse(code).task == "a\nb\tc中😀")
    }

    @Test func rejectsShapesThatAreNotDelegationCalls() {
        let negatives = [
            "not json at all",
            #"{"code":42}"#,
            "{}",
            #"{"command":"ls"}"#,
            // A different method on the same accessor is an execute call, not ours.
            payload(#"tools["codeg-mcp"].list_agents({})"#),
            // `tools.search` is a plain method call, not an accessor chain.
            payload(#"tools.search({ query: "delegate_to_agent" })"#),
            // The call shape inside a string/template/comment is not a call site.
            payload(#"const s = "tools[\"codeg-mcp\"].delegate_to_agent(""#),
            payload(#"const t = `tools["codeg-mcp"].delegate_to_agent()`"#),
            payload(#"// tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode" })"#),
        ]
        for raw in negatives {
            #expect(!C.isCodeModeDelegationInput(raw), "\(raw)")
            let parsed = D.parseInput(raw)
            #expect(parsed.agentType == nil, "\(raw)")
            #expect(parsed.task == nil, "\(raw)")
        }
    }

    @Test func keepsTheCardRenderableWhenAValueIsUnreadable() {
        // `${…}` interpolation evaluates differently than the source reads.
        let interp = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: `hi ${name}` })"#
        #expect(isInput(interp))
        #expect(parse(interp) == DelegationParsedInput(agentType: agent("zcode"), assistantId: nil, task: nil, workingDir: nil))

        // An escape outside the minimal set bails the same way.
        let unknownEscape = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: `a\qb` })"#
        #expect(isInput(unknownEscape))
        #expect(parse(unknownEscape).task == nil)

        // An escaped quoted task could decode differently than it reads.
        let escapedQuoted = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "a\nb" })"#
        #expect(isInput(escapedQuoted))
        #expect(parse(escapedQuoted).task == nil)

        // No agent_type / an unknown slug: still a call, generic card.
        let noAgent = #"tools["codeg-mcp"].delegate_to_agent({ task: `t` })"#
        #expect(isInput(noAgent))
        #expect(parse(noAgent).agentType == nil)

        let badAgent = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "nope", task: `t` })"#
        #expect(parse(badAgent).agentType == nil)
    }

    @Test func readsAStringifiedAssistantIdWithoutMistakingTheTarget() {
        let code = #"tools["codeg-mcp"].delegate_to_agent({ assistant_id: "3", agent_type: "codex", task: `t` })"#
        #expect(isInput(code))
        let parsed = parse(code)
        #expect(parsed.assistantId == 3)
        #expect(parsed.agentType == .codex)
        #expect(parsed.task == "t")
    }

    @Test func readsABareNumericAssistantIdInEverySpelling() {
        let bare = parse(#"tools["codeg-mcp"].delegate_to_agent({ assistant_id: 3, agent_type: "codex", task: `t` })"#)
        #expect(bare.assistantId == 3)
        #expect(bare.agentType == .codex)
        #expect(parse(#"tools["codeg-mcp"].delegate_to_agent({ "assistant_id": 3, task: `t` })"#).assistantId == 3)
        #expect(parse(#"tools["codeg-mcp"].delegate_to_agent({ "assistant_id": "3", task: `t` })"#).assistantId == 3)
        // A bare number NOT ending its property is not the value.
        #expect(parse(#"tools["codeg-mcp"].delegate_to_agent({ assistant_id: 3 + 1, task: `t` })"#).assistantId == nil)
    }

    @Test func degradesTheParseWhenWorkingDirIsPresentButUnreadable() {
        let cases = [
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", working_dir: "C:\\proj", task: `t` })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", working_dir: `${cwd}/proj`, task: `t` })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", working_dir: projectDir, task: `t` })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", working_dir: "/tmp" + "/w", task: `t` })"#,
        ]
        for code in cases {
            #expect(isInput(code), "\(code)")
            let parsed = parse(code)
            #expect(parsed.workingDir == nil, "\(code)")
            #expect(parsed.agentType == .codex, "\(code)")
            #expect(parsed.task == "t", "\(code)")
        }
    }

    @Test func doesNotReadAValueThatContinuesPastItsLiteral() {
        let taskConcat = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "a" + b })"#
        #expect(parse(taskConcat).task == nil)
        #expect(parse(taskConcat).agentType == .codex)

        #expect(parse(#"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `a`.trim() })"#).task == nil)

        let agentConcat = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "co" + "dex", task: `t` })"#
        #expect(parse(agentConcat).agentType == nil)
        #expect(parse(agentConcat).task == "t")

        let dirConcat = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", working_dir: "/a" + suffix, task: `t` })"#
        #expect(parse(dirConcat).workingDir == nil)
        #expect(parse(dirConcat).task == "t")

        // Duplicate keys take the LAST spelling — the one the runtime uses.
        #expect(parse(#"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `stale`, task: `fresh` })"#).task
                == "fresh")
        // …and a later unreadable spelling degrades the read.
        #expect(parse(#"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `stale`, task: "a" + b })"#).task
                == nil)
    }

    @Test func acceptsCommentsBetweenValuesAndTheirPropertyTerminators() {
        let code = #"""
        tools["codeg-mcp"].delegate_to_agent({
          // choose the agent
          agent_type: "codex", /* trailing */ task: `t` /* last */, // done
        })
        """#
        #expect(isInput(code))
        let parsed = parse(code)
        #expect(parsed.agentType == .codex)
        #expect(parsed.task == "t")
    }

    @Test func readsQuotedPropertyKeysAndIgnoresNestedSameNamedKeys() {
        let quoted = #"tools["codeg-mcp"].delegate_to_agent({ "agent_type": "codex", 'task': "plain" })"#
        #expect(isInput(quoted))
        #expect(parse(quoted).agentType == .codex)
        #expect(parse(quoted).task == "plain")

        // The backend reads FLAT args, so a same-named key inside a sub-object
        // must not surface — in either source order.
        let nested = #"""
        tools["codeg-mcp"].delegate_to_agent({
          meta: { agent_type: "zzz", task: `decoy` },
          agent_type: "codex",
          task: `real`,
        })
        """#
        #expect(parse(nested).agentType == .codex)
        #expect(parse(nested).task == "real")

        let nestedRev = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `real`, meta: { task: `decoy`, agent_type: "zzz" } })"#
        #expect(parse(nestedRev).agentType == .codex)
        #expect(parse(nestedRev).task == "real")
    }

    @Test func screensUnknowableArgumentSyntaxOutOfTheParseEntirely() {
        let cases = [
            #"tools["codeg-mcp"].delegate_to_agent({ ...base, task: `t` })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ ["assistant_id"]: 3, agent_type: "codex", task: `t` })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ ["agent_type"]: "codex", task: `t` })"#,
        ]
        for code in cases {
            #expect(isInput(code), "\(code)")
            #expect(parse(code) == empty, "\(code)")
        }
    }

    @Test func normalizesTemplateLineTerminatorsTheWayTheJSRuntimeCooksThem() {
        // Bare CR and CRLF collapse to a single LF; a backslash line
        // continuation contributes nothing.
        let crlf = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `a"# + "\r\nb\rc" + #"` })"#
        #expect(parse(crlf).task == "a\nb\nc")

        // U+2028/U+2029 are JS line terminators but NOT normalized.
        let ls = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `a"# + "\u{2028}" + #"b` })"#
        #expect(parse(ls).task == "a\u{2028}b")

        let ps = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `a"# + "\u{2029}" + #"b` })"#
        #expect(parse(ps).task == "a\u{2029}b")

        let cont = #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `a\"# + "\r\n" + #"b` })"#
        #expect(parse(cont).task == "ab")
    }

    @Test func bailsToTheGenericRowWhenArgsSyntaxIsUnreadable() {
        // Shorthand properties evaluate to the variable's runtime value; nested
        // calls and regex literals are expressions the scanner cannot evaluate.
        let cases = [
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `t`, working_dir })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `t`, assistant_id })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: pick("codex"), task: `t` })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `t`, flag: /}/ })"#,
        ]
        for code in cases {
            #expect(isInput(code), "\(code)")
            #expect(parse(code) == empty, "\(code)")
        }
    }

    @Test func readsNothingUnlessTheArgumentIsExactlyOneObjectLiteral() {
        // A second argument object makes OpenCode throw "expects at most one
        // input object" before any MCP call.
        let cases = [
            #"tools["codeg-mcp"].delegate_to_agent(c ? { agent_type: "codex", task: `a` } : { agent_type: "codex", task: `b` })"#,
            #"tools["codeg-mcp"].delegate_to_agent(x || { agent_type: "codex", task: `decoy` })"#,
            #"tools["codeg-mcp"].delegate_to_agent(x ?? { agent_type: "codex", task: `decoy` })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `t` }.y)"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `t` }, { agent_type: "goose", task: `u` })"#,
            #"tools["codeg-mcp"].delegate_to_agent(args)"#,
        ]
        for code in cases {
            #expect(isInput(code), "\(code)")
            #expect(parse(code) == empty, "\(code)")
        }
        // A trailing comma still leaves exactly one argument.
        #expect(parse(#"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `t` }, /* end */ )"#).task == "t")
    }

    @Test func readsNothingWhenLaterSyntaxCanOverrideOrHideAKey() {
        // A later shorthand, a Unicode-escaped key, a ternary (whose string
        // reads like a key before its `:`), and a duplicate key behind
        // non-ASCII whitespace the word matcher cannot see.
        let cases = [
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "decoy", task })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "t", agent_type })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "decoy", \u0074ask: "real" })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: c ? "task" : "real" })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: c ? "agent_type" : "codex", task: "t" })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: obj?.task })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "decoy","# + "\u{00A0}" + #"task: "real" })"#,
            #"tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "decoy","# + "\u{FEFF}" + #"task: "real" })"#,
        ]
        for code in cases {
            #expect(isInput(code), "\(code)")
            let parsed = parse(code)
            #expect(parsed.task == nil, "\(code)")
            #expect(parsed.agentType == nil, "\(code)")
        }
    }

    @Test func classifiesOnlyOpencodesExecuteToolByItsCode() {
        // Another tool's `code` argument — a Playwright script that mocks the
        // call — is no delegation; the backend doesn't register it either.
        let raw = payload("async page => { const tools = {'codeg-mcp': {delegate_to_agent: async x => x}}; await tools['codeg-mcp'].delegate_to_agent({agent_type:'codex',task:'review'}); }")
        #expect(C.isCodeModeDelegationInput(raw))
        // `execute` normalizes to `bash`, live and in history.
        #expect(C.isCodeModeDelegationCall(normalizedToolName: "bash", input: raw))
        #expect(!C.isCodeModeDelegationCall(normalizedToolName: "mcp__playwright__browser_run_code", input: raw))
    }

    @Test func declinesAScriptWithASlashBeforeTheCall() {
        // `/'/` opens a "string" that skips the real call and closes in a later
        // comment, whose example then reads as the call site.
        let desync = #"const re = /'/;"# + "\n"
            + #"await tools["codeg-mcp"].delegate_to_agent({agent_type:"codex",task:"real"});"# + "\n"
            + #"// here's an example: tools["codeg-mcp"].delegate_to_agent({agent_type:"codex",task:"decoy"})"#
        #expect(!isInput(desync))

        // After a call that runs first, a slash changes nothing…
        let after = #"const r = await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "t" }); return r.ms / 1000"#
        #expect(parse(after).task == "t")

        // …after one that may not run, it hides whether another site exists.
        let unsure = #"if (bad) { await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "t" }) } const n = 4 / 2"#
        #expect(isInput(unsure))
        #expect(parse(unsure).task == nil)
    }

    static let runsFirst: [(code: String, task: String)] = [
        (#"await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }); await tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })"#, "A"),
        (#"const [a, b] = await Promise.allSettled([tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }), tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })])"#, "A"),
        // A lone call reads wherever it sits: if it runs, it is the call.
        (#"if (failed) { await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "fix" }) }"#, "fix"),
        (#"const r = await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }); await tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" }); return `${r.task_id}`"#, "A"),
        (#"await Promise.allSettled([tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }), tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })]).then(rs => rs)"#, "A"),
        (#"return await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" })"#, "A"),
    ]

    /// The first site may not run while a later one does: a branch, a deferred
    /// function or parameter default, a destructuring default, or a `${…}` the
    /// count cannot see; one case per construct.
    static let mayNotRunFirst = [
        #"const later = (x = tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "decoy" })) => x; await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "real" })"#,
        #"const later = async (x = tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "decoy" })) => x; await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "real" })"#,
        #"function later(x = tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "decoy" })) { return x } await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "real" })"#,
        #"const [a = tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "decoy" })] = [1]; await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "real" })"#,
        #"if (false) { await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "decoy" }) } const text = `${await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "real" })}`"#,
        #"const text = `${await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "real" })}`; if (c) { await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "decoy" }) }"#,
        #"c && await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }); await tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })"#,
        #"c || await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }); await tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })"#,
        #"switch (c) {} await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }); await tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })"#,
        #"for (const x of xs) {} await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }); await tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })"#,
        #"while (false) {} await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }); await tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })"#,
        #"do {} while (false); await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }); await tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })"#,
        #"try {} catch (e) {} await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }); await tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })"#,
        #"const t = `${await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "real" })}`; return t; await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }); await tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })"#,
        #"const f = (x = tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "decoy" }), y = 1 / 2) => x; await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "real" })"#,
        #"if (false) { await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "decoy" }) } await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "real" })"#,
        #"c ? tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }) : tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })"#,
        #"if (c) await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }); else await tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })"#,
        #"const later = () => tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }); await tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })"#,
        #"async function go() { await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: "A" }) } await tools["codeg-mcp"].delegate_to_agent({ agent_type: "zcode", task: "B" })"#,
    ]

    @Test func readsTheFirstOfSeveralCallsOnlyWhenItRunsFirst() {
        for (code, task) in Self.runsFirst {
            #expect(isInput(code), "\(code)")
            #expect(parse(code).task == task, "\(code)")
        }
        for code in Self.mayNotRunFirst {
            #expect(isInput(code), "\(code)")
            #expect(parse(code).task == nil, "\(code)")
        }
    }

    @Test func capsTheScriptInUTF8BytesAsTheBackendDoes() {
        let call = #"tools.codeg_mcp.delegate_to_agent({agent_type:"codex",task:"t"})"#
        // 350,000 CJK characters are 1,050,000 bytes: past the 1 MiB cap the
        // backend measures, though under it in UTF-16 units.
        #expect(!isInput("/*" + String(repeating: "中", count: 350_000) + "*/" + call))
        #expect(isInput("/*" + String(repeating: "a", count: (1 << 20) - 200) + "*/" + call))
    }

    @Test func endsLineCommentsAtEveryJSLineTerminator() {
        // ECMA-262 line comments end at CR, LF, U+2028 and U+2029.
        let cr = #"tools["codeg-mcp"].delegate_to_agent({ // pick"# + "\r" + #" agent_type: "codex", task: `t` })"#
        #expect(parse(cr).task == "t")

        let ls = "// delegate\u{2028}" + #"await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `t` })"#
        #expect(isInput(ls))
        #expect(parse(ls).task == "t")

        // Inside the argument object the terminator is non-ASCII code the word
        // matcher cannot delimit, so the read degrades rather than guesses.
        let lsInArgs = #"tools["codeg-mcp"].delegate_to_agent({ // pick"# + "\u{2028}" + #" agent_type: "codex", task: `t` })"#
        #expect(isInput(lsInArgs))
        #expect(parse(lsInArgs).task == nil)
    }
}

// iOS: the card a code-mode delegation gets. Its `ToolCallVM.companion` is
// what picks `DelegatedSubThreadCard`, so it has to agree with the activity
// step `DescribeToolCall.kind` gives the call.
@MainActor
@Suite("code-mode delegations draw as delegation cards")
struct CodeModeDelegationCardTests {
    private static let code = #"await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `Review the patch.` })"#

    private func vm(rawName: String, input: String?, toolName: String? = nil) -> ToolCallVM {
        ToolCallVM(id: "c1", rawName: rawName, kind: "", state: .done, input: input, output: nil,
                   content: nil, isError: false, toolName: toolName)
    }

    @Test func aPersistedExecuteCallIsADelegation() {
        let call = vm(rawName: "execute", input: payload(Self.code))
        #expect(call.companion == .delegate)
        #expect(DescribeToolCall.kind(call) == .delegation)
    }

    @Test func aLiveCallStaysOneOnceTheBrokerStampsIt() {
        // Live, the title is `execute`; the broker's `codeg.delegation` meta
        // turns the inferred name into `delegate_to_agent`.
        let live = vm(rawName: "execute", input: payload(Self.code), toolName: "delegate_to_agent")
        #expect(live.companion == .delegate)
        #expect(DescribeToolCall.kind(live) == .delegation)
    }

    @Test func aLiveCallTheBrokerStampedIsOneWhateverItsInput() {
        let live = ToolCallVM(id: "c1", rawName: "MCP: tool", kind: "", state: .running, input: "{}",
                              output: nil, content: nil, isError: false,
                              meta: .object(["codeg.delegation": .object(["task_id": .string("t1")])]),
                              toolName: "delegate_to_agent")
        #expect(live.companion == .delegate)
    }

    // A title quotes anything: inferred from one, the name is no evidence.
    @Test func aCommandWhoseTitleQuotesTheToolKeepsItsCard() {
        let bash = vm(rawName: "rg 'delegate_to_agent'", input: #"{"command":"rg 'delegate_to_agent'"}"#,
                      toolName: "delegate_to_agent")
        #expect(bash.companion == nil)
    }

    @Test func anyOtherScriptOrToolStaysWhatItWas() {
        #expect(vm(rawName: "execute", input: payload("return 1 + 1")).companion == nil)
        #expect(vm(rawName: "mcp__playwright__browser_run_code", input: payload(Self.code)).companion == nil)
    }

    @Test func theCardReadsTheAgentAndTaskOutOfTheCode() {
        let parsed = D.parseInput(payload(Self.code))
        #expect(parsed.agentType == .codex)
        #expect(parsed.task == "Review the patch.")
    }
}
