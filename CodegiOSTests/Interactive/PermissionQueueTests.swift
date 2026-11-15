import Foundation
import Testing
@testable import Codeg

/// The permission queue and the answers to it (codeg 0.44): `queued` /
/// `permission_queue_depth` on the card, the `tool_approval` records and the
/// snapshot's `tool_approvals`, the request that announces its call on the
/// rail (web `PERMISSION_REQUEST`), and the live overlay a row draws with
/// (web `useLiveToolStep` / `useAwaitedStep` / `showsApproval`).
@MainActor
struct PermissionQueueTests {
    private func event(_ json: String) throws -> AcpEvent {
        try CodegJSON.decoder.decode(AcpEvent.self, from: Data(json.utf8))
    }

    private func snapshot(_ json: String) throws -> LiveSessionSnapshot {
        try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(json.utf8))
    }

    // MARK: Decoding

    @Test func aRequestCarriesHowManyWaitBehindIt() throws {
        let decoded = try event(#"""
        {"type":"permission_request","request_id":"r1","tool_call":{"toolCallId":"c1"},"options":[],"queued":3}
        """#)
        guard case .permissionRequest(let id, _, _, let queued) = decoded else { Issue.record("decoded \(decoded)"); return }
        #expect(id == "r1")
        #expect(queued == 3)
    }

    @Test func aRequestFromAnOlderServerWaitsOnNoOne() throws {
        for extra in ["", #","queued":-2"#, #","queued":"many""#] {
            let decoded = try event(#"{"type":"permission_request","request_id":"r1","tool_call":{},"options":[]"# + extra + "}")
            guard case .permissionRequest(_, _, _, let queued) = decoded else { Issue.record("decoded \(decoded)"); return }
            #expect(queued == 0, "\(extra)")
        }
    }

    @Test func theQueueDepthDecodes() throws {
        let decoded = try event(#"{"type":"permission_queue_depth","depth":2}"#)
        guard case .permissionQueueDepth(let depth) = decoded else { Issue.record("decoded \(decoded)"); return }
        #expect(depth == 2)
    }

    @Test func anApprovalRecordDecodes() throws {
        let decoded = try event(#"""
        {"type":"tool_approval","approval":{"tool_call_id":"c1","option_kind":"allow_always",
         "option_name":"Always Allow","origin":"chat_channel","decided_at":"2026-11-15T09:41:12Z"}}
        """#)
        guard case .toolApproval(let info) = decoded else { Issue.record("decoded \(decoded)"); return }
        #expect(info == ToolApprovalInfo(toolCallId: "c1", optionKind: "allow_always", optionName: "Always Allow",
                                         origin: "chat_channel", decidedAt: "2026-11-15T09:41:12Z"))
    }

    @Test func aRecordMissingOnlyItsAnnotationsStillCounts() throws {
        let decoded = try event(#"{"type":"tool_approval","approval":{"tool_call_id":"c1","option_kind":"reject_once"}}"#)
        guard case .toolApproval(let info) = decoded else { Issue.record("decoded \(decoded)"); return }
        #expect(info.optionKind == "reject_once")
        #expect(info.optionName.isEmpty && info.origin.isEmpty && info.decidedAt.isEmpty)
    }

    @Test func aRecordAboutNoCallIsNotAnApproval() throws {
        for approval in [#"{"option_kind":"allow_once"}"#, #"{"tool_call_id":"","option_kind":"allow_once"}"#,
                         #"{"tool_call_id":"c1"}"#, #""allow_once""#] {
            let decoded = try event(#"{"type":"tool_approval","approval":"# + approval + "}")
            guard case .unknown(let type) = decoded else { Issue.record("decoded \(decoded) for \(approval)"); continue }
            #expect(type == "tool_approval")
        }
    }

    @Test func aSnapshotCarriesTheQueueAndTheAnswersSoFar() throws {
        let snap = try snapshot(#"""
        {"connection_id":"k","status":"prompting",
         "pending_permission":{"request_id":"r1","tool_call":{"toolCallId":"c2"},"options":[],"queued":1},
         "tool_approvals":[
           {"tool_call_id":"c1","option_kind":"allow_once","option_name":"Yes","origin":"user","decided_at":"2026-11-15T09:00:00Z"},
           {"tool_call_id":"c9"},
           {"tool_call_id":"","option_kind":"allow_once"},
           {"tool_call_id":"c3","option_kind":"reject_once","option_name":"No","origin":"user","decided_at":"2026-11-15T09:01:00Z"}
         ]}
        """#)
        #expect(snap.pendingPermission?.queued == 1)
        // One record this build can't read drops alone.
        #expect(snap.toolApprovals.map(\.toolCallId) == ["c1", "c3"])
    }

    @Test func aSnapshotWithoutApprovalsHasNone() throws {
        let snap = try snapshot(#"{"connection_id":"k","pending_permission":{"request_id":"r1","tool_call":{},"options":[]}}"#)
        #expect(snap.toolApprovals.isEmpty)
        #expect(snap.pendingPermission?.queued == 0)
        let garbled = try snapshot(#"{"connection_id":"k","tool_approvals":{"c1":"allow_once"}}"#)
        #expect(garbled.toolApprovals.isEmpty)
    }

    // MARK: The request's call

    @Test func theRequestsInputIsItsNestedInputOrWhatIsLeftOfIt() throws {
        let nested = AnyJSON(any: ["toolCallId": "c1", "title": "Bash", "rawInput": ["command": "npm test"]] as [String: Any])
        #expect(PermissionLiveMerge.requestInput(nested) == #"{"command":"npm test"}"#)
        let asText = AnyJSON(any: ["toolCallId": "c1", "rawInput": #"{"command":"ls"}"#] as [String: Any])
        #expect(PermissionLiveMerge.requestInput(asText) == #"{"command":"ls"}"#)
        // A blank input is none: the wrapper's own fields are stripped from the rest.
        let flat = AnyJSON(any: ["toolCallId": "c1", "kind": "fetch", "status": "pending", "title": "Fetch",
                                 "rawInput": "  ", "url": "https://a.dev"] as [String: Any])
        #expect(PermissionLiveMerge.requestInput(flat) == #"{"url":"https://a.dev"}"#)
        let bare = AnyJSON(any: ["toolCallId": "c1", "title": "Tool"] as [String: Any])
        #expect(PermissionLiveMerge.requestInput(bare) == nil)
        #expect(PermissionLiveMerge.requestInput(.string("x")) == nil)
    }

    @Test func theRequestNamesItsCallByTitleAndKind() throws {
        let request = try CodegJSON.decoder.decode(AnyJSON.self, from: Data(#"{"tool_name":"WebFetch","kind":" "}"#.utf8))
        #expect(PermissionLiveMerge.requestTitle(request) == "WebFetch")
        #expect(PermissionLiveMerge.requestKind(request) == "WebFetch")
        let named = AnyJSON(any: ["title": "Run tests", "kind": "execute"] as [String: Any])
        #expect(PermissionLiveMerge.requestTitle(named) == "Run tests")
        #expect(PermissionLiveMerge.requestKind(named) == "execute")
    }

    @Test func aRequestAheadOfItsCallAnnouncesItPending() {
        let live = LiveTurn()
        #expect(live.noteAwaitedCall(id: "net-1", title: "", kind: "tool", rawInput: #"{"host":"a.dev"}"#))
        guard case .tool(let call)? = live.segments.last else { Issue.record("no call on the rail"); return }
        #expect(call.id == "net-1")
        #expect(call.status == "pending")
        #expect(call.title == "Tool")
        #expect(call.rawInput == #"{"host":"a.dev"}"#)
        // Its own `tool_call` takes the entry over, in place.
        live.upsertToolCall(id: "net-1", title: "SandboxNetworkAccess", kind: "other", status: "in_progress",
                            rawInput: #"{"host":"b.dev"}"#, rawOutput: nil, content: nil)
        #expect(live.segments.count == 1)
        #expect(call.title == "SandboxNetworkAccess")
        #expect(call.rawInput == #"{"host":"b.dev"}"#)
    }

    @Test func aRequestFillsOnlyACallThatSentNoInput() {
        let live = LiveTurn()
        live.upsertToolCall(id: "c1", title: "Bash", kind: "execute", status: "pending",
                            rawInput: nil, rawOutput: nil, content: nil)
        #expect(live.noteAwaitedCall(id: "c1", title: "Bash", kind: "execute", rawInput: #"{"command":"ls"}"#))
        live.upsertToolCall(id: "c2", title: "Bash", kind: "execute", status: "pending",
                            rawInput: #"{"command":"pwd"}"#, rawOutput: nil, content: nil)
        #expect(!live.noteAwaitedCall(id: "c2", title: "Bash", kind: "execute", rawInput: #"{"command":"rm"}"#))
        let inputs = live.segments.compactMap { segment -> String? in
            if case .tool(let call) = segment { return call.rawInput }
            return nil
        }
        #expect(inputs == [#"{"command":"ls"}"#, #"{"command":"pwd"}"#])
    }

    @Test func aRefreshedCardKeepsItsPlaceInTheQueue() throws {
        let live = LiveTurn()
        let pending = PendingPermission(
            requestId: "r1",
            toolCall: AnyJSON(any: ["toolCallId": "c1", "title": "a.dev", "rawInput": ["host": "a.dev"]] as [String: Any]),
            options: [], queued: 2)
        #expect(pending.toolCallId == "c1")
        live.upsertToolCall(id: "c1", title: "SandboxNetworkAccess", kind: "other", status: "pending",
                            rawInput: nil, rawOutput: nil, content: nil,
                            meta: AnyJSON(any: ["claudeCode": ["toolName": "SandboxNetworkAccess"]] as [String: Any]))
        let refreshed = try #require(pending.refreshed(by: live, toolCallId: "c1"))
        #expect(refreshed.queued == 2)
    }

    // MARK: The live overlay

    private func step(_ id: String, state: ToolCallState = .running, output: String? = nil,
                      isError: Bool = false, meta: AnyJSON? = nil) -> ActivityToolStep {
        let call = ToolCallVM(id: id, rawName: "Bash", kind: "", state: state, input: #"{"command":"make"}"#,
                              output: output, content: nil, isError: isError, meta: meta)
        return ActivityToolStep(key: "tool:\(id)", call: call, tool: DescribeToolCall.describe(call))
    }

    private func info(_ id: String, _ kind: String, at: String = "2026-11-15T09:00:00Z") -> ToolApprovalInfo {
        ToolApprovalInfo(toolCallId: id, optionKind: kind, optionName: "Allow", origin: "user", decidedAt: at)
    }

    @Test func theCallARequestIsAboutWaitsOnTheUser() {
        let live = ActivityLive(awaitingToolCallId: "c1", approvals: [:])
        #expect(live.tool(for: step("c1")).status == .awaiting)
        #expect(live.tool(for: step("c2")).status == .running)
        // One already settled is not waiting on anyone, whatever the card says.
        #expect(live.tool(for: step("c1", state: .done, output: "ok")).status == .succeeded)
        #expect(live.tool(for: step("c1", state: .error, output: "boom", isError: true)).status == .failed)
        #expect(ActivityLive.none.tool(for: step("c1")).status == .running)
    }

    @Test func aGroupHoldingTheAwaitedCallSaysSo() {
        let live = ActivityLive(awaitingToolCallId: "c2", approvals: [:])
        let steps = [step("c1", state: .done, output: "ok"), step("c2"), step("c3")]
        #expect(live.awaitedStep(in: steps)?.call.id == "c2")
        #expect(ActivityLive.none.awaitedStep(in: steps) == nil)
        #expect(ActivityLive(awaitingToolCallId: "c1", approvals: [:]).awaitedStep(in: steps) == nil)
    }

    @Test func aCallTheUserDeclinedReadsDeclined() {
        let live = ActivityLive(awaitingToolCallId: nil, approvals: ["c1": info("c1", "reject_once")])
        let failed = live.tool(for: step("c1", state: .error, output: "exit 1", isError: true))
        #expect(failed.status == .rejected)
        #expect(failed.approval?.decision == .rejected)
        // It already says "declined": the chip would only say it twice.
        #expect(!ActivityLive.showsApproval(failed.approval, status: failed.status))
        // A declined call the transcript shows succeeding keeps its status and shows the chip.
        let ran = live.tool(for: step("c1", state: .done, output: "ok"))
        #expect(ran.status == .succeeded)
        #expect(ActivityLive.showsApproval(ran.approval, status: ran.status))
    }

    @Test func theConnectionsRecordWinsOverTheStamp() {
        let stamp = AnyJSON(any: ["codeg.approval": ["option_kind": "allow_once", "option_name": "Yes"]] as [String: Any])
        let stamped = step("c1", state: .done, output: "ok", meta: stamp)
        #expect(ActivityLive.none.tool(for: stamped).approval?.decision == .allowOnce)
        let live = ActivityLive(awaitingToolCallId: nil, approvals: ["c1": info("c1", "allow_always")])
        #expect(live.tool(for: stamped).approval?.decision == .allowAlways)
        // A record of a kind this build doesn't know leaves the stamp standing.
        let unknown = ActivityLive(awaitingToolCallId: nil, approvals: ["c1": info("c1", "allow_maybe")])
        #expect(unknown.tool(for: stamped).approval?.decision == .allowOnce)
    }

    @Test func aCallNobodyWasAskedAboutIsLeftAlone() {
        let live = ActivityLive(awaitingToolCallId: "c9", approvals: ["c8": info("c8", "allow_once")])
        let given = step("c1", state: .done, output: "ok")
        #expect(live.tool(for: given) == given.tool)
        #expect(!ActivityLive.showsApproval(nil, status: .succeeded))
    }
}
