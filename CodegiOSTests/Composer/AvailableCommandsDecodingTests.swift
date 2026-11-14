import Foundation
import Testing
@testable import Codeg

/// `available_commands` on every wire it rides: the live event, the snapshot
/// frame, the by-conversation snapshot and the draft probe.
@Suite struct AvailableCommandsDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try CodegJSON.decoder.decode(type, from: Data(json.utf8))
    }

    @Test func theLiveEventReplacesTheList() throws {
        let event = try decode(AcpEvent.self, #"""
        {"type":"available_commands","commands":[
          {"name":"review","description":"Review the branch","input_hint":"branch name"},
          {"name":"simplify","description":"","skill":true},
          {"name":"user-skill","description":"Mine","skill":true,"skill_path":"/u/SKILL.md"},
          {"name":"$deploy","description":"Deploy"}
        ]}
        """#)
        guard case .availableCommands(let commands) = event else { Issue.record("decoded \(event)"); return }
        #expect(commands.map(\.name) == ["review", "simplify", "user-skill", "$deploy"])
        #expect(commands[0].inputHint == "branch name")
        #expect(!commands[0].skill)
        #expect(commands[1].skill && commands[1].skillPath == nil)
        #expect(commands[2].skillPath == "/u/SKILL.md")
    }

    @Test func anEmptyListIsAList() throws {
        let envelope = try decode(EventEnvelope.self,
                                  #"{"seq":3,"connection_id":"c1","type":"available_commands","commands":[]}"#)
        guard case .availableCommands(let commands) = envelope.event else { Issue.record("decoded \(envelope.event)"); return }
        #expect(commands.isEmpty)
        #expect(envelope.seq == 3)
    }

    @Test func aListThatDoesNotDecodeIsNotAnEmptyOne() throws {
        let event = try decode(AcpEvent.self, #"{"type":"available_commands","commands":[{"description":"no name"}]}"#)
        #expect(event == .unknown(type: "available_commands"))
        let missing = try decode(AcpEvent.self, #"{"type":"available_commands"}"#)
        #expect(missing == .unknown(type: "available_commands"))
    }

    @Test func theAttachSnapshotCarriesThem() throws {
        let message = try decode(WSServerMessage.self, #"""
        {"type":"snapshot","subscription_id":"s","connection_id":"c","event_seq":5,
         "snapshot":{"connection_id":"c","status":"connected",
                     "available_commands":[{"name":"compact","description":"Compact"}]}}
        """#)
        guard case .snapshot(let snapshot) = message else { Issue.record("not a snapshot"); return }
        #expect(snapshot.availableCommands?.map(\.name) == ["compact"])
        #expect(snapshot.eventSeq == 5)
    }

    @Test func aSnapshotWithoutThemSaysNothingAboutThem() throws {
        let snapshot = try decode(LiveSessionSnapshot.self, #"{"connection_id":"c","status":"connected"}"#)
        #expect(snapshot.availableCommands == nil)
        let broken = try decode(LiveSessionSnapshot.self, #"{"connection_id":"c","available_commands":"nope"}"#)
        #expect(broken.availableCommands == nil, "a shape surprise must not fail the snapshot")
        #expect(broken.connectionId == "c")
    }

    @Test func theConversationSnapshotCarriesSkillMarks() throws {
        let snapshot = try decode(SessionSnapshot.self, #"""
        {"selectors_ready":true,"available_commands":[{"name":"loop","description":"Loop","skill":true}]}
        """#)
        #expect(snapshot.availableCommands.first?.skill == true)
    }

    @Test func theDraftProbeCarriesThem() throws {
        let probe = try decode(AgentOptionsSnapshot.self, #"""
        {"modes":null,"config_options":[],
         "available_commands":[{"name":"init","description":"Init","input_hint":null}]}
        """#)
        #expect(probe.availableCommands.map(\.name) == ["init"])
        let older = try decode(AgentOptionsSnapshot.self, #"{"modes":null,"config_options":[]}"#)
        #expect(older.availableCommands.isEmpty)
    }
}
