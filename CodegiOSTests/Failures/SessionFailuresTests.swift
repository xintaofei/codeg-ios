import Foundation
import Testing
@testable import Codeg

/// Port of the web's `src/lib/session-failures.test.ts` and
/// `session-notices.test.ts` (codeg 0.44), plus the iOS dock projection.
private func record(_ id: String, _ revision: Int, category: String = "limit", severity: String = "warning",
                    title: String? = nil, details: String? = nil, actions: [String] = ["retry"],
                    resolved: Bool = false, dismissed: Bool = false) -> SessionFailureRecord {
    SessionFailureRecord(id: id, revision: revision, category: category, severity: severity,
                         title: title ?? "\(id)@\(revision)", details: details, actions: actions,
                         resolved: resolved, dismissed: dismissed)
}

private func find(_ table: [SessionFailureRecord], _ id: String) -> SessionFailureRecord? {
    table.first { $0.id == id }
}

@Suite struct SessionFailureMergeTests {
    @Test func acceptsFreshIdsAndStrictlyHigherRevisionsInPlace() {
        var table = SessionFailures.merge([], [record("a", 1)])
        table = SessionFailures.merge(table, [record("b", 1)])
        table = SessionFailures.merge(table, [record("a", 2, title: "revised")])
        #expect(table.count == 2)
        #expect(find(table, "a")?.title == "revised")
        #expect(table.map(\.id) == ["a", "b"])
    }

    @Test func rejectsEqualAndLowerRevisions() {
        let table = SessionFailures.merge([], [record("a", 2)])
        #expect(SessionFailures.merge(table, [record("a", 2, title: "replay")]) == table)
        #expect(SessionFailures.merge(table, [record("a", 1)]) == table)
    }

    @Test func adoptsAnEqualRevisionResolutionASnapshotCarries() {
        let table = SessionFailures.merge([], [record("a", 2)])
        #expect(table[0].resolved == false)
        let hydrated = SessionFailures.merge(table, [record("a", 2, resolved: true)])
        #expect(hydrated[0].resolved == true)
        #expect(hydrated[0].revision == 2)
        // Only false → true.
        #expect(SessionFailures.merge(hydrated, [record("a", 2)]) == hydrated)
        // A genuine recurrence re-arms through a higher revision.
        #expect(SessionFailures.merge(hydrated, [record("a", 3)])[0].resolved == false)
    }

    @Test func resolvedEntriesKeepTheirWatermark() {
        var table = SessionFailures.merge([], [record("a", 2)])
        table = SessionFailures.settle(table, .all)
        #expect(table[0].resolved)
        #expect(SessionFailures.merge(table, [record("a", 2)]) == table)
        #expect(SessionFailures.merge(table, [record("a", 1)]) == table)
        let rearmed = SessionFailures.merge(table, [record("a", 3)])
        #expect(rearmed[0].resolved == false)
        #expect(rearmed[0].revision == 3)
    }

    @Test func reArmsOnEscalationThroughIdReuse() {
        var table = SessionFailures.merge([], [record("t1:error", 1)])
        table = SessionFailures.settle(table, .warnings)
        table = SessionFailures.merge(table, [record("t1:error", 2, severity: "error", title: "gave up")])
        #expect(table.count == 1)
        #expect(table[0].severity == "error")
        #expect(table[0].resolved == false)
    }

    @Test func mergesSnapshotBatchesMonotonically() {
        let live = [record("a", 3), record("b", 1)]
        let merged = SessionFailures.merge(live, [record("a", 2), record("b", 2), record("c", 1)])
        #expect(find(merged, "a")?.revision == 3)
        #expect(find(merged, "b")?.revision == 2)
        #expect(find(merged, "c") != nil)
        #expect(SessionFailures.merge(merged, [record("a", 1)]) == merged)
        #expect(SessionFailures.merge(merged, []) == merged)
        // No usable identity: skipped.
        #expect(SessionFailures.merge(merged, [record("", 1), record("d", 0)]) == merged)
    }
}

@Suite struct SessionFailureSettleTests {
    @Test func settlesWarningsAtTurnBoundariesErrorsSurvive() {
        let table = [record("w", 1), record("e", 1, severity: "error")]
        let settled = SessionFailures.settle(table, .warnings)
        #expect(find(settled, "w")?.resolved == true)
        #expect(find(settled, "e")?.resolved == false)
        #expect(SessionFailures.settle(settled, .all).allSatisfy { $0.resolved })
    }

    @Test func settlesRetryIncidentsOnProgressSparingNoticesAndErrors() {
        let table = [
            record("conn", 1, category: "connection"),
            record("svc", 1, category: "service"),
            record("notice", 1, category: "unknown"),
            record("err", 1, category: "connection", severity: "error"),
        ]
        let settled = SessionFailures.settle(table, .retryIncidents)
        #expect(find(settled, "conn")?.resolved == true)
        #expect(find(settled, "svc")?.resolved == true)
        #expect(find(settled, "notice")?.resolved == false)
        #expect(find(settled, "err")?.resolved == false)
        let atTurnEnd = SessionFailures.settle(settled, .warnings)
        #expect(find(atTurnEnd, "notice")?.resolved == true)
        #expect(find(atTurnEnd, "err")?.resolved == false)
    }

    @Test func activeRetryIncidentIsAnUnresolvedNonUnknownWarning() {
        #expect(!SessionFailures.hasActiveRetryIncident([]))
        #expect(!SessionFailures.hasActiveRetryIncident([record("n", 1, category: "unknown")]))
        #expect(!SessionFailures.hasActiveRetryIncident([record("e", 1, severity: "error")]))
        #expect(!SessionFailures.hasActiveRetryIncident([record("c", 1, category: "connection", resolved: true)]))
        #expect(SessionFailures.hasActiveRetryIncident([record("c", 1, category: "connection")]))
    }
}

@Suite struct SessionFailureDismissTests {
    @Test func resolvesJustThoseIdsAndKeepsThemAsWatermarks() {
        let table = [record("a", 2), record("b", 1)]
        let next = SessionFailures.dismiss(table, ids: ["a"])
        #expect(find(next, "a")?.resolved == true)
        #expect(find(next, "b")?.resolved == false)
        #expect(SessionFailures.merge(next, [record("a", 2)]) == next)
        let rearmed = find(SessionFailures.merge(next, [record("a", 3)]), "a")
        #expect(rearmed?.resolved == false)
        #expect(rearmed?.dismissed == false)
    }

    @Test func closesEveryIdOneCollapsedStripStoodFor() {
        let next = SessionFailures.dismiss([record("w1", 1), record("w2", 1), record("w3", 1)], ids: ["w1", "w2", "w3"])
        #expect(next.allSatisfy { $0.resolved && $0.dismissed })
        #expect(SessionFailures.activeRetryIncidentView(next).incident == nil)
    }

    @Test func dismissalNeverRendersAsRecovery() {
        let table = SessionFailures.dismiss([record("w", 1)], ids: ["w"])
        #expect(table[0].dismissed)
        #expect(SessionFailures.mostRecentRecoveredWarning(table) == nil)
    }

    @Test func silencesAnAlreadyResolvedRecord() {
        let next = SessionFailures.dismiss([record("a", 1, resolved: true)], ids: ["a"])
        #expect(next[0].resolved && next[0].dismissed)
        #expect(SessionFailures.mostRecentRecoveredWarning(next) == nil)
    }

    @Test func survivesASnapshotThatNeverSawTheDismissal() {
        let dismissed = SessionFailures.dismiss([record("w", 1)], ids: ["w"])
        let hydrated = SessionFailures.merge(dismissed, [record("w", 1, resolved: false)])
        #expect(hydrated == dismissed)
        #expect(hydrated.allSatisfy { $0.resolved })
    }
}

@Suite struct SessionFailureSelectorTests {
    @Test func mostRecentRecoveredPicksTheLatestSelfSettledWarning() {
        let table = [
            record("w1", 1, resolved: true),
            record("w2", 1, resolved: true),
            record("e1", 1, severity: "error", resolved: true),
            record("w3", 1),
        ]
        #expect(SessionFailures.mostRecentRecoveredWarning(table)?.id == "w2")
        let afterDismiss = SessionFailures.dismiss(table, ids: ["w2"])
        #expect(SessionFailures.mostRecentRecoveredWarning(afterDismiss)?.id == "w1")
        #expect(SessionFailures.mostRecentRecoveredWarning(SessionFailures.dismiss(afterDismiss, ids: ["w1"])) == nil)
        #expect(SessionFailures.mostRecentRecoveredWarning([]) == nil)
        #expect(SessionFailures.mostRecentRecoveredWarning([record("w", 1)]) == nil)
    }

    @Test func neverAnnouncesASweptAdvisoryAsRecovered() {
        let advisory = record("adv", 1, category: "unknown", resolved: true)
        #expect(SessionFailures.mostRecentRecoveredWarning([advisory]) == nil)
        let incident = record("inc", 1, category: "connection", resolved: true)
        #expect(SessionFailures.mostRecentRecoveredWarning([incident, advisory])?.id == "inc")
    }

    @Test func latestActiveTerminalFailure() {
        #expect(SessionFailures.latestActiveTerminalFailure([]) == nil)
        #expect(SessionFailures.latestActiveTerminalFailure([record("w", 1)]) == nil)
        #expect(SessionFailures.latestActiveTerminalFailure([record("e", 1, severity: "error", resolved: true)]) == nil)
        #expect(SessionFailures.latestActiveTerminalFailure([
            record("e1", 1, severity: "error"), record("e2", 1, severity: "error"), record("w", 1),
        ])?.id == "e2")
        // An unrecognized severity is terminal.
        #expect(SessionFailures.latestActiveTerminalFailure([record("x", 1, severity: "fatal")])?.id == "x")
    }

    @Test func activeIncidentsCollapseToTheLatestPlusACount() {
        let view = SessionFailures.activeRetryIncidentView([
            record("w1", 1), record("w2", 1), record("w3", 1), record("gone", 1, resolved: true),
        ])
        #expect(view.incident?.id == "w3")
        #expect(view.hiddenCount == 2)
        #expect(view.ids == ["w1", "w2", "w3"])

        let news = SessionFailures.activeRetryIncidentView([
            record("e", 1, severity: "error"), record("advisory", 1, category: "unknown"), record("w", 1),
        ])
        #expect(news.incident?.id == "w")
        #expect(news.hiddenCount == 0)
        #expect(news.ids == ["w"])

        let empty = SessionFailures.activeRetryIncidentView([record("w", 1, resolved: true), record("e", 1, severity: "error")])
        #expect(empty == .init(incident: nil, hiddenCount: 0, ids: []))
    }
}

@Suite struct SessionFailureNoticeTests {
    private func terminal(_ revision: Int = 1, title: String? = nil, details: String? = nil,
                          actions: [String] = ["retry"], resolved: Bool = false, severity: String = "error",
                          id: String = "t") -> SessionFailureRecord {
        record(id, revision, category: "access", severity: severity, title: title ?? "t@1",
               details: details, actions: actions, resolved: resolved)
    }
    private func advisory(_ revision: Int = 1, title: String? = nil, resolved: Bool = false) -> SessionFailureRecord {
        record("a", revision, category: "unknown", title: title ?? "a@1", actions: [], resolved: resolved)
    }

    @Test func tellsANewTerminalFailureAndANewAdvisory() {
        #expect(SessionFailures.notice(stored: nil, incoming: terminal()) == .terminal)
        #expect(SessionFailures.notice(stored: nil, incoming: advisory()) == .advisory)
        #expect(SessionFailures.notice(stored: nil, incoming: terminal(severity: "fatal")) == .terminal)
    }

    @Test func neverTellsARetryIncident() {
        #expect(SessionFailures.notice(stored: nil, incoming: record("w", 1)) == nil)
        #expect(SessionFailures.notice(stored: record("w", 1), incoming: record("w", 2, title: "again")) == nil)
    }

    @Test func tellsAnIncidentEscalatedToATerminalFailure() {
        #expect(SessionFailures.notice(stored: record("x", 1), incoming: record("x", 2, severity: "error")) == .terminal)
    }

    @Test func staysQuietForStaleAndReplayedRevisions() {
        #expect(SessionFailures.notice(stored: terminal(2), incoming: terminal()) == nil)
        #expect(SessionFailures.notice(stored: terminal(), incoming: terminal()) == nil)
        #expect(SessionFailures.notice(stored: nil, incoming: terminal(id: "")) == nil)
        #expect(SessionFailures.notice(stored: nil, incoming: terminal(0)) == nil)
    }

    @Test func staysQuietForARepublishThatChangesNothing() {
        #expect(SessionFailures.notice(stored: advisory(), incoming: advisory(2)) == nil)
        #expect(SessionFailures.notice(stored: terminal(), incoming: terminal(2)) == nil)
    }

    @Test func tellsARevisionThatSaysSomethingNew() {
        #expect(SessionFailures.notice(stored: advisory(), incoming: advisory(2, title: "Different")) == .advisory)
        #expect(SessionFailures.notice(stored: terminal(), incoming: terminal(2, details: "now with a reason")) == .terminal)
        #expect(SessionFailures.notice(stored: terminal(actions: ["login"]), incoming: terminal(2, actions: ["login", "retry"])) == .terminal)
    }

    @Test func tellsTheSameWordingAgainOnceSettled() {
        #expect(SessionFailures.notice(stored: advisory(resolved: true), incoming: advisory(2)) == .advisory)
        #expect(SessionFailures.notice(stored: terminal(resolved: true), incoming: terminal(2)) == .terminal)
    }
}

/// iOS's projection of web `SessionFailureBanner` + `ComposerStatusStrips`.
@Suite struct SessionFailureDockTests {
    @Test func incidentsShowOnlyWhileATurnRunsAndNoRetryLineDoes() {
        let table = [record("w", 1, category: "connection")]
        #expect(SessionFailures.dock(table, turnRunning: true, retryLineShown: false).incident?.incident?.id == "w")
        #expect(SessionFailures.dock(table, turnRunning: false, retryLineShown: false).incident == nil)
        #expect(SessionFailures.dock(table, turnRunning: true, retryLineShown: true).incident == nil)
    }

    @Test func recoveredLineWaitsUntilNothingIsFailing() {
        let recovered = record("old", 1, category: "connection", resolved: true)
        #expect(SessionFailures.dock([recovered], turnRunning: true, retryLineShown: false).recovered?.id == "old")
        // An incident still in flight — even a hidden one — means nothing recovered yet.
        let active = [recovered, record("w", 1, category: "connection")]
        #expect(SessionFailures.dock(active, turnRunning: true, retryLineShown: true).recovered == nil)
        // Nor once the turn failed after all.
        let failed = [recovered, record("e", 1, severity: "error")]
        #expect(SessionFailures.dock(failed, turnRunning: false, retryLineShown: false).recovered == nil)
        #expect(SessionFailures.dock([], turnRunning: true, retryLineShown: false).isEmpty)
    }
}

@Suite struct SessionNoticeTests {
    @Test func splitsAHeadlineFromTheRest() {
        let split = SessionNotices.splitHeadline("\n  Upstream failed  \n{\"error\":1}\n", more: " retry later ")
        #expect(split?.title == "Upstream failed")
        #expect(split?.description == "{\"error\":1}\nretry later")
        #expect(SessionNotices.splitHeadline("Only a title")?.description == nil)
        #expect(SessionNotices.splitHeadline("  \n ") == nil)
        #expect(SessionNotices.splitHeadline("a\r\nb")?.title == "a")
    }

    @Test func dropsNoticesThatOnlyRestateACompaction() {
        #expect(SessionNotices.present(SessionNoticeInfo(severity: "warning",
            title: "Heads up: Long threads and multiple compactions can cause the model to be less accurate.")) == nil)
        #expect(SessionNotices.present(SessionNoticeInfo(severity: "info", title: " Context compacted ")) == nil)
        // A warning that says "context compacted" is something else.
        #expect(SessionNotices.present(SessionNoticeInfo(severity: "warning", title: "Context compacted")) == "Context compacted")
        #expect(SessionNotices.present(SessionNoticeInfo(severity: "info", title: "Model switched", description: "to gpt-5")) == "Model switched\nto gpt-5")
        #expect(SessionNotices.present(SessionNoticeInfo(severity: "info", title: "  ")) == nil)
    }

    @Test func pluginFailuresNameEachPluginInTheCliWords() {
        let failures = [
            PluginLoadFailure(plugin: "fmt@market", kind: "hook", message: "bad hook", path: nil),
            PluginLoadFailure(plugin: "inline[0]", kind: "path-not-found", message: "", path: "/p/x"),
            PluginLoadFailure(plugin: "fmt@market", kind: "mcp", message: "no server", path: nil),
        ]
        let text = SessionNotices.present(failures)
        let lines = text?.components(separatedBy: "\n") ?? []
        #expect(lines.count == 4)
        #expect(lines[1] == "fmt@market: bad hook")
        #expect(lines[2] == "/p/x (path-not-found)")
        #expect(lines[3] == "fmt@market: no server")
        #expect(SessionNotices.present([PluginLoadFailure]()) == nil)
    }

    @Test func sessionArchivedOffersTheCommandOnlyForCodexAndAUuid() {
        let uuid = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
        let codex = SessionNotices.sessionLoadFailure(code: "session_archived", message: "raw", sessionId: uuid,
                                                      agent: "Codex", agentIsCodex: true)
        #expect(codex.contains("codex unarchive \(uuid)"))
        #expect(SessionNotices.sessionLoadFailure(code: "session_archived", message: "raw", sessionId: uuid,
                                                  agent: "Claude", agentIsCodex: false) == "raw")
        #expect(SessionNotices.sessionLoadFailure(code: "session_archived", message: "raw", sessionId: "x; rm -rf ~",
                                                  agent: "Codex", agentIsCodex: true) == "raw")
        #expect(SessionNotices.sessionLoadFailure(code: "future_code", message: "agent text", sessionId: uuid,
                                                  agent: "Codex", agentIsCodex: true) == "agent text")
    }
}

@Suite struct TurnRetryStateTests {
    @Test func readsClaudesApiRetryAndNothingElse() {
        let json = AnyJSON.parse(jsonString: #"{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"error":"overloaded_error","error_status":529,"retry_delay_ms":4000}"#)
        let retry = TurnRetryState.fromClaudeSdkMessage(json)
        #expect(retry == TurnRetryState(attempt: 2, maxRetries: 10, error: "overloaded_error", errorStatus: 529,
                                        retryDelayMs: 4000, reportsError: true))
        // Converted keys (the shared decoder's snake-case conversion) read too.
        let camel = AnyJSON.parse(jsonString: #"{"type":"system","subtype":"api_retry","maxRetries":"3","retryDelayMs":500}"#)
        #expect(TurnRetryState.fromClaudeSdkMessage(camel)?.maxRetries == 3)
        #expect(TurnRetryState.fromClaudeSdkMessage(camel)?.retryDelayMs == 500)
        #expect(TurnRetryState.fromClaudeSdkMessage(AnyJSON.parse(jsonString: #"{"type":"system","subtype":"init"}"#)) == nil)
        #expect(TurnRetryState.fromClaudeSdkMessage(nil) == nil)
    }

    @Test func turnRetryingDecodesPisCountersWithoutInventingACause() throws {
        let data = Data(#"{"type":"turn_retrying","message":"","attempt":1,"max_retries":3,"retry_delay_ms":2000}"#.utf8)
        let event = try CodegJSON.decoder.decode(AcpEvent.self, from: data)
        guard case .turnRetrying(let retry) = event else { Issue.record("decoded \(event)"); return }
        #expect(retry.error == nil)
        #expect(retry.reportsError == false)
        #expect(retry.attempt == 1)
        #expect(retry.maxRetries == 3)
        #expect(retry.retryDelayMs == 2000)
    }

    @Test func sessionFailureAndSnapshotTableDecode() throws {
        let data = Data(#"{"type":"session_failure","record":{"id":"t1","revision":2,"category":"connection","severity":"warning","title":"Reconnecting","actions":["retry"]}}"#.utf8)
        let event = try CodegJSON.decoder.decode(AcpEvent.self, from: data)
        guard case .sessionFailure(let rec) = event else { Issue.record("decoded \(event)"); return }
        #expect(rec.id == "t1" && rec.revision == 2 && rec.resolved == false && rec.actions == ["retry"])

        let snap = try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(
            #"{"status":"prompting","session_failures":[{"id":"t1","revision":2,"category":"connection","severity":"warning","title":"x","resolved":true}]}"#.utf8))
        #expect(snap.sessionFailures.first?.resolved == true)
    }
}
