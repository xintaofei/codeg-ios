import Foundation
import Testing
@testable import Codeg

/// The connection's advisories and the two facts about its process the screen
/// docks banners for: Remote Control and config staleness (web
/// `REMOTE_CONTROL` / `CONFIG_STALE_CHANGED` / `DISMISS_CONFIG_STALE` /
/// `HYDRATE_FROM_SNAPSHOT`, and the `config_option_rejected` /
/// `session_load_failed` handlers).
private func event(_ json: [String: Any]) throws -> AcpEvent {
    let data = try JSONSerialization.data(withJSONObject: json)
    return try CodegJSON.decoder.decode(AcpEvent.self, from: data)
}

private func snapshot(seq: UInt64, externalId: String = "s1", status: String = "connected",
                      _ extra: [String: Any] = [:]) throws -> LiveSessionSnapshot {
    var json: [String: Any] = ["connection_id": "c1", "status": status, "external_id": externalId, "event_seq": seq]
    json.merge(extra) { _, new in new }
    let data = try JSONSerialization.data(withJSONObject: json)
    return try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: data)
}

private let link = "https://claude.ai/code/session_01ABC"

@Suite struct SessionAdvisoryDecodingTests {
    @Test func decodesARejectedPickWithItsLabels() throws {
        let decoded = try event([
            "type": "config_option_rejected", "config_id": "model", "option_name": "Model",
            "requested": "Opus 4.7", "actual": "Sonnet 4.6",
            "requested_value": "opus", "actual_value": "sonnet",
        ])
        guard case .configOptionRejected(let rejection) = decoded else {
            Issue.record("got \(decoded)"); return
        }
        #expect(rejection == ConfigOptionRejection(configId: "model", optionName: "Model",
                                                   requested: "Opus 4.7", actual: "Sonnet 4.6"))
    }

    @Test func aRejectionWithoutItsOptionIsUnknown() throws {
        guard case .unknown = try event(["type": "config_option_rejected", "requested": "a", "actual": "b"]) else {
            Issue.record("expected unknown"); return
        }
    }

    @Test func decodesStalenessAndItsKind() throws {
        guard case .sessionConfigStale(true, .modelProvider) =
                try event(["type": "session_config_stale", "stale": true, "kind": "model_provider"]) else {
            Issue.record("model provider"); return
        }
        guard case .sessionConfigStale(false, .agentConfig) =
                try event(["type": "session_config_stale", "stale": false, "kind": "agent_config"]) else {
            Issue.record("reverted"); return
        }
        // A kind from a later server is still a drift, just unnamed.
        guard case .sessionConfigStale(true, nil) =
                try event(["type": "session_config_stale", "stale": true, "kind": "mcp_servers"]) else {
            Issue.record("unknown kind"); return
        }
        guard case .unknown = try event(["type": "session_config_stale", "kind": "agent_config"]) else {
            Issue.record("no verdict is no event"); return
        }
    }

    @Test func decodesRemoteControlOnAndOff() throws {
        guard case .remoteControl(let on?) = try event(["type": "remote_control", "remote_control": ["session_url": link]]) else {
            Issue.record("on"); return
        }
        #expect(on.sessionUrl == link)
        guard case .remoteControl(nil) = try event(["type": "remote_control", "remote_control": NSNull()]) else {
            Issue.record("null is off"); return
        }
        guard case .remoteControl(nil) = try event(["type": "remote_control"]) else {
            Issue.record("absent is off"); return
        }
        // On, without a link.
        guard case .remoteControl(let bare?) = try event(["type": "remote_control", "remote_control": ["session_url": "  "]]) else {
            Issue.record("on without a link"); return
        }
        #expect(bare.sessionUrl == nil)
    }

    @Test func theSnapshotCarriesBothFacts() throws {
        let snap = try snapshot(seq: 3, [
            "remote_control": ["session_url": link], "config_stale": true, "config_stale_kind": "agent_config",
        ])
        #expect(snap.runs.remoteControl?.sessionUrl == link)
        #expect(snap.runs.configStale)
        #expect(snap.runs.configStaleKind == .agentConfig)
        // An older server sends neither.
        let plain = try snapshot(seq: 3)
        #expect(plain.runs.remoteControl == nil)
        #expect(!plain.runs.configStale)
        #expect(plain.runs.configStaleKind == nil)
    }

    @Test func onlyAWebLinkOpens() {
        #expect(RemoteControlInfo(sessionUrl: link).openableURL?.host == "claude.ai")
        #expect(RemoteControlInfo(sessionUrl: "javascript:alert(1)").openableURL == nil)
        #expect(RemoteControlInfo(sessionUrl: "file:///etc/passwd").openableURL == nil)
        #expect(RemoteControlInfo(sessionUrl: "https://").openableURL == nil)
        #expect(RemoteControlInfo(sessionUrl: nil).openableURL == nil)
    }
}

@MainActor
@Suite struct RemoteControlStateTests {
    @Test func followsTheEventsAndTheSnapshot() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 5, ["remote_control": ["session_url": link]]), connection: "c1")
        #expect(model.remoteControl?.sessionUrl == link)
        model.apply(.remoteControl(nil), seq: 6)
        #expect(model.remoteControl == nil)
        model.apply(.remoteControl(RemoteControlInfo(sessionUrl: link)), seq: 7)
        #expect(model.remoteControl != nil)
        // A fresh snapshot without it: off.
        try model.hydrate(snapshot(seq: 9), connection: "c1")
        #expect(model.remoteControl == nil)
    }

    @Test func goesWithTheAgentProcess() throws {
        for status in [ConnectionStatus.disconnected, .error] {
            let model = ConnectionRunsModel()
            try model.hydrate(snapshot(seq: 5, ["remote_control": ["session_url": link]]), connection: "c1")
            model.apply(.statusChanged(status: .connected), seq: 6)
            #expect(model.remoteControl != nil, "a status the process survives keeps it")
            model.apply(.statusChanged(status: status), seq: 7)
            #expect(model.remoteControl == nil, "\(status)")
        }
    }

    @Test func aForkLeavesItBehindAndAReplayedStartDoesNot() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 5, externalId: "s1", ["remote_control": ["session_url": link]]), connection: "c1")
        model.apply(.sessionStarted(sessionId: "s1"), seq: 6)
        #expect(model.remoteControl != nil)
        model.apply(.sessionStarted(sessionId: "s2"), seq: 7)
        #expect(model.remoteControl == nil)
    }

    @Test func aStaleSnapshotCannotBringItBack() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 5, ["remote_control": ["session_url": link]]), connection: "c1")
        model.apply(.remoteControl(nil), seq: 8)
        try model.hydrate(snapshot(seq: 5, ["remote_control": ["session_url": link]]), connection: "c1")
        #expect(model.remoteControl == nil)
    }

    @Test func anotherConnectionStartsOver() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 5, ["remote_control": ["session_url": link], "config_stale": true]),
                          connection: "c1")
        try model.hydrate(snapshot(seq: 1), connection: "c2")
        #expect(model.remoteControl == nil)
        #expect(model.configStale == nil)
        model.connectionGone("c2")
        #expect(model.remoteControl == nil)
    }

    @Test func knowsWhenATurnIsRunning() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 5, status: "prompting"), connection: "c1")
        #expect(model.isPrompting)
        model.apply(.statusChanged(status: .connected), seq: 6)
        #expect(!model.isPrompting)
        model.apply(.statusChanged(status: .prompting), seq: 7)
        #expect(model.isPrompting)
        model.clear()
        #expect(!model.isPrompting)
    }
}

@MainActor
@Suite struct ConfigStaleStateTests {
    @Test func aDriftShowsAndARevertClears() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 5), connection: "c1")
        #expect(model.configStale == nil)
        model.apply(.sessionConfigStale(stale: true, kind: .modelProvider), seq: 6)
        #expect(model.configStale == ConfigStale(kind: .modelProvider, dismissed: false))
        model.apply(.sessionConfigStale(stale: false, kind: .modelProvider), seq: 7)
        #expect(model.configStale == nil)
    }

    @Test func aDismissalHoldsUntilAFreshDrift() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 5), connection: "c1")
        model.apply(.sessionConfigStale(stale: true, kind: .agentConfig), seq: 6)
        model.dismissConfigStale()
        #expect(model.configStale?.dismissed == true)
        // Every watch after a turn opens with a snapshot restating it.
        try model.hydrate(snapshot(seq: 9, ["config_stale": true, "config_stale_kind": "agent_config"]),
                          connection: "c1")
        #expect(model.configStale?.dismissed == true)
        // Another save: a new drift, shown again.
        model.apply(.sessionConfigStale(stale: true, kind: .agentConfig), seq: 10)
        #expect(model.configStale?.dismissed == false)
    }

    @Test func aSnapshotOfAnotherKindIsADriftNeverSeen() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 5), connection: "c1")
        model.apply(.sessionConfigStale(stale: true, kind: .agentConfig), seq: 6)
        model.dismissConfigStale()
        try model.hydrate(snapshot(seq: 9, ["config_stale": true, "config_stale_kind": "model_provider"]),
                          connection: "c1")
        #expect(model.configStale == ConfigStale(kind: .modelProvider, dismissed: false))
    }

    @Test func aLateAttachLearnsItFromTheSnapshot() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 5, ["config_stale": true, "config_stale_kind": "model_provider"]),
                          connection: "c1")
        #expect(model.configStale == ConfigStale(kind: .modelProvider))
        try model.hydrate(snapshot(seq: 7, ["config_stale": false]), connection: "c1")
        #expect(model.configStale == nil)
    }

    @Test func dismissingNothingDoesNothing() {
        let model = ConnectionRunsModel()
        model.dismissConfigStale()
        #expect(model.configStale == nil)
    }
}

@Suite struct SessionAdvisoryTextTests {
    @Test func saysWhatTheAgentSettledOn() {
        let text = SessionNotices.configOptionAdjusted(
            ConfigOptionRejection(configId: "model", optionName: "Model", requested: "Opus", actual: "Sonnet"),
            agent: "Grok")
        #expect(text.contains("Grok"))
        #expect(text.contains("Model"))
        #expect(text.contains("Sonnet"))
        #expect(text.contains("Opus"))
        // No display name: the option's id stands in.
        let bare = SessionNotices.configOptionAdjusted(
            ConfigOptionRejection(configId: "thought_level", optionName: "", requested: "high", actual: "low"),
            agent: "pi")
        #expect(bare.contains("thought_level"))
    }

    @Test func offersTheUnarchiveCommandOnlyForACodexRolloutId() {
        let uuid = "0199a0b1-2c3d-7e8f-9a0b-1c2d3e4f5a6b"
        #expect(SessionNotices.recoveryCommand(code: "session_archived", sessionId: uuid, agentIsCodex: true)
                == "codex unarchive \(uuid)")
        #expect(SessionNotices.recoveryCommand(code: "session_archived", sessionId: uuid, agentIsCodex: false) == nil)
        #expect(SessionNotices.recoveryCommand(code: "resource_not_found", sessionId: uuid, agentIsCodex: true) == nil)
        #expect(SessionNotices.recoveryCommand(code: "session_archived", sessionId: "\(uuid); rm -rf ~",
                                               agentIsCodex: true) == nil)
    }

    @Test func finishedBackgroundTasksAreToldOncePerBatch() {
        #expect(SessionNotices.backgroundSettled([], agent: "Claude Code") == nil)
        #expect(SessionNotices.backgroundSettled([BackgroundSettled(taskId: "a", status: "completed", interim: true)],
                                                 agent: "Claude Code") == nil, "it will report again")
        let one = SessionNotices.backgroundSettled(
            [BackgroundSettled(taskId: "a", status: "completed", summary: " Audit finished ")], agent: "Claude Code")
        #expect(one?.hasPrefix("Claude Code") == true)
        #expect(one?.hasSuffix("Audit finished") == true, "the summary, trimmed")
        let bare = SessionNotices.backgroundSettled([BackgroundSettled(taskId: "a", status: "failed")], agent: "Claude Code")
        #expect(bare?.contains("failed") == true)
        let many = SessionNotices.backgroundSettled(
            [BackgroundSettled(taskId: "a", status: "completed"), BackgroundSettled(taskId: "b", status: "completed"),
             BackgroundSettled(taskId: "c", status: "completed", interim: true)], agent: "Claude Code")
        #expect(many?.contains("2") == true)
    }

    @Test func anUnconfirmedLoadNamesTheAgent() {
        #expect(SessionNotices.sessionLoadUnconfirmed(agent: "Codex").contains("Codex"))
    }
}
