import Foundation
import Testing
@testable import Codeg

/// `src/lib/activity/approval.test.ts`, plus the iOS decoder's camelCased meta
/// and the `Date.parse` port the merge orders by.
struct ActivityApprovalTests {
    private func info(_ toolCallId: String, _ optionKind: String, _ decidedAt: String = "2026-10-22T09:00:00Z") -> ToolApprovalInfo {
        ToolApprovalInfo(toolCallId: toolCallId, optionKind: optionKind, optionName: "Allow", origin: "user", decidedAt: decidedAt)
    }

    private func meta(_ object: [String: Any]) -> AnyJSON { AnyJSON(any: object) }

    // MARK: approvalFromMeta

    @Test func approvalFromMetaReadsTheStampADetailLoadPutsOnAToolCall() {
        let raw: [String: Any] = [
            "codeg.delegation": ["status": "completed"],
            "codeg.approval": [
                "option_kind": "allow_always",
                "option_name": "Always Allow",
                "origin": "chat_channel",
                "decided_at": "2026-10-22T09:41:12Z",
            ],
        ]
        let expected = ToolApproval(decision: .allowAlways, optionName: "Always Allow", origin: "chat_channel", decidedAt: "2026-10-22T09:41:12Z")
        #expect(ActivityApproval.approvalFromMeta(rawMeta: raw) == expected)
        #expect(ActivityApproval.approvalFromMeta(meta(raw)) == expected)
    }

    @Test func approvalFromMetaFoldsBothRejectionKindsIntoOneDecision() {
        for kind in ["reject_once", "reject_always"] {
            let raw: [String: Any] = ["codeg.approval": ["option_kind": kind]]
            #expect(ActivityApproval.approvalFromMeta(rawMeta: raw)?.decision == .rejected)
            #expect(ActivityApproval.approvalFromMeta(meta(raw))?.decision == .rejected)
        }
    }

    @Test func approvalFromMetaIgnoresAMissingMalformedOrUnknownStamp() {
        #expect(ActivityApproval.approvalFromMeta(nil) == nil)
        #expect(ActivityApproval.approvalFromMeta(rawMeta: nil) == nil)
        #expect(ActivityApproval.approvalFromMeta(rawMeta: [:]) == nil)
        #expect(ActivityApproval.approvalFromMeta(meta([:])) == nil)
        #expect(ActivityApproval.approvalFromMeta(rawMeta: ["codeg.approval": "allow_once"]) == nil)
        #expect(ActivityApproval.approvalFromMeta(meta(["codeg.approval": "allow_once"])) == nil)
        #expect(ActivityApproval.approvalFromMeta(rawMeta: ["codeg.approval": ["option_kind": "maybe_later"]]) == nil)
        #expect(ActivityApproval.approvalFromMeta(meta(["codeg.approval": ["option_kind": "maybe_later"]])) == nil)
    }

    @Test func approvalFromMetaReadsTheStampTheSnakeCaseDecoderCamelCased() throws {
        struct Envelope: Decodable { let meta: AnyJSON }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let wire = #"{"meta":{"codeg.approval":{"option_kind":"allow_once","option_name":"Yes","decided_at":"2026-10-22T09:41:12Z","origin":"  "}}}"#
        let decoded = try decoder.decode(Envelope.self, from: Data(wire.utf8))
        #expect(ActivityApproval.approvalFromMeta(decoded.meta)
            == ToolApproval(decision: .allowOnce, optionName: "Yes", origin: nil, decidedAt: "2026-10-22T09:41:12Z"))
    }

    // MARK: approvalFromInfo

    @Test func approvalFromInfoKeepsOneObjectPerRecordSoRowsKeepTheirProps() {
        // The web caches by record identity; a Swift value is equal by value.
        let record = info("tc-1", "allow_once")
        let approval = ActivityApproval.approvalFromInfo(record)
        #expect(approval?.decision == .allowOnce)
        #expect(ActivityApproval.approvalFromInfo(record) == approval)
    }

    @Test func toolApprovalInfoDecodesThroughTheSharedSnakeCaseDecoder() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let wire = #"{"tool_call_id":"tc-1","option_kind":"allow_once","option_name":"Allow","origin":"user","decided_at":"2026-10-22T09:00:00Z"}"#
        #expect(try decoder.decode(ToolApprovalInfo.self, from: Data(wire.utf8)) == info("tc-1", "allow_once"))
    }

    // MARK: mergeToolApprovals

    @Test func mergeToolApprovalsKeepsOneRecordPerCallTheLaterDecisionWinning() {
        let first = info("tc-1", "allow_once", "2026-10-22T09:00:00Z")
        let later = info("tc-1", "reject_once", "2026-10-22T09:05:00Z")
        let other = info("tc-2", "allow_always")
        let merged = ActivityApproval.mergeToolApprovals(ActivityApproval.emptyToolApprovals, [first, other, later])
        #expect(merged == ["tc-1": later, "tc-2": other])
        // An older record arriving afterwards cannot walk it back.
        #expect(ActivityApproval.mergeToolApprovals(merged, [first]) == merged)
    }

    @Test func mergeToolApprovalsReturnsTheMapItselfWhenNothingChanges() {
        let record = info("tc-1", "allow_once")
        let merged = ActivityApproval.mergeToolApprovals(ActivityApproval.emptyToolApprovals, [record])
        #expect(ActivityApproval.mergeToolApprovals(merged, [record]) == merged)
        #expect(ActivityApproval.mergeToolApprovals(merged, []) == merged)
        #expect(ActivityApproval.mergeToolApprovals(merged, nil) == merged)
    }

    @Test func mergeToolApprovalsLetsADatedRecordReplaceAnUndatedOne() {
        // An unparsable time reads as 0 (`NaN` on the web), so any real time wins.
        let undated = info("tc-1", "allow_once", "soon")
        let dated = info("tc-1", "reject_once")
        #expect(ActivityApproval.mergeToolApprovals(["tc-1": undated], [dated]) == ["tc-1": dated])
        #expect(ActivityApproval.mergeToolApprovals(["tc-1": dated], [undated]) == ["tc-1": dated])
    }

    // MARK: parseDateMs

    @Test func parseDateMsReadsTheIsoFormsDateParseDoes() {
        #expect(ActivityApproval.parseDateMs("1970-01-01T00:00:00Z") == 0)
        #expect(ActivityApproval.parseDateMs("1970-01-01T00:00:01.5Z") == 1500)
        #expect(ActivityApproval.parseDateMs("1970-01-01T00:00:00.123456789Z") == 123)
        #expect(ActivityApproval.parseDateMs("1970-01-01T01:00:00+01:00") == 0)
        #expect(ActivityApproval.parseDateMs("1970-01-02") == 86_400_000)
        #expect(ActivityApproval.parseDateMs("2026-10-22T09:05:00Z")! > ActivityApproval.parseDateMs("2026-10-22T09:00:00Z")!)
        #expect(ActivityApproval.parseDateMs("not a date") == nil)
        #expect(ActivityApproval.parseDateMs("2026-13-01") == nil)
    }
}
