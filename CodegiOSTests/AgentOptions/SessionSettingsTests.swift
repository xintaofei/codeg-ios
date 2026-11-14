import Foundation
import Testing
@testable import Codeg

// MARK: - Fixtures

private func opt(_ value: String, _ name: String? = nil, _ description: String? = nil) -> SessionConfigSelectOption {
    SessionConfigSelectOption(value: value, name: name ?? value, description: description)
}

private func select(
    _ id: String, _ name: String, _ category: String?, _ current: String,
    _ options: [SessionConfigSelectOption], recommended: String? = nil
) -> SessionConfigOption {
    SessionConfigOption(
        id: id, name: name, description: nil, category: category,
        kind: .select(currentValue: current, options: options, groups: []),
        recommendedValue: recommended
    )
}

private func select(_ id: String, _ name: String, _ category: String?, _ current: String, _ values: [String]) -> SessionConfigOption {
    select(id, name, category, current, values.map { opt($0) })
}

private func boolean(_ id: String, _ name: String, _ on: Bool) -> SessionConfigOption {
    SessionConfigOption(id: id, name: name, description: nil, category: nil, kind: .boolean(currentValue: on))
}

private func mode(_ id: String, _ name: String, _ description: String? = nil) -> SessionModeInfo {
    SessionModeInfo(id: id, name: name, description: description)
}

private func build(
    _ configOptions: [SessionConfigOption],
    modes: [SessionModeInfo] = [],
    currentModeId: String? = nil
) -> [SessionSetting] {
    SessionSettings.build(configOptions: configOptions, modes: modes, currentModeId: currentModeId, modeTitle: "Mode")
}

private func choice(_ setting: SessionSetting?) throws -> SessionChoice {
    try #require(setting?.choice)
}

private func toggle(_ setting: SessionSetting?) throws -> (isOn: Bool, onValue: String, offValue: String) {
    guard case .toggle(let isOn, let onValue, let offValue)? = setting?.control else {
        Issue.record("not a switch")
        throw CancellationError()
    }
    return (isOn, onValue, offValue)
}

private func isToggle(_ setting: SessionSetting) -> Bool {
    if case .toggle = setting.control { return true }
    return false
}

/// What claude-agent-acp 0.88 advertises, in its own order.
private let claude: [SessionConfigOption] = [
    select("mode", "Mode", "mode", "default", [
        opt("default", "Manual", "Always ask"),
        opt("plan", "Plan", "Plan first"),
    ]),
    select("model", "Model", "model", "opus", [
        opt("opus", "Opus 5.5", "Best for everyday"),
        opt("haiku", "Haiku 5.5"),
    ], recommended: "opus"),
    select("effort", "Effort", "thought_level", "high", ["low", "medium", "high"].map { opt($0) }, recommended: "medium"),
    select("fast", "Fast mode", "model_config", "off", ["on", "off"]),
]

// MARK: - Order (`session-settings.test.ts` — order)

struct SessionSettingsOrderTests {
    @Test func putsTheModelFirstThenEffortModeOtherSelectsSwitches() {
        // codex-acp 2.2.2's order: mode, collaboration mode, model, effort, fast.
        let settings = build([
            select("mode", "Mode", "mode", "agent", ["read-only", "agent"]),
            select("collaboration_mode", "Collaboration mode", "collaboration_mode", "default", ["default", "plan"]),
            select("fast_mode", "Fast mode", "model_config", "on", ["off", "on"]),
            select("model", "Model", "model", "gpt-6", ["gpt-6", "gpt-5"]),
            select("reasoning_effort", "Reasoning effort", "thought_level", "low", ["low", "high"]),
        ])
        #expect(settings.map(\.key) == [
            "config:model", "config:reasoning_effort", "config:mode",
            "config:collaboration_mode", "config:fast_mode",
        ])
    }

    @Test func keepsTheAgentsOrderWithinARank() {
        // Cline 3.0.62: both Provider and Model are `category: "model"`.
        let settings = build([
            select("provider", "Provider", "model", "cline", ["cline", "anthropic"]),
            select("model", "Model", "model", "a", ["a", "b"]),
            boolean("auto_approve", "Auto-approve tools", true),
            select("mode", "Session Mode", "mode", "act", ["plan", "act"]),
        ])
        #expect(settings.map(\.key) == ["config:provider", "config:model", "config:mode", "config:auto_approve"])
    }

    @Test func ranksTheLegacyModeListAsAMode() throws {
        let settings = build([], modes: [mode("default", "Default", "Prompts"), mode("yolo", "YOLO")], currentModeId: "yolo")
        #expect(settings.first?.target == .mode)
        #expect(settings.first?.title == "Mode")
        #expect(try choice(settings.first).currentLabel == "YOLO")
        #expect(settings.first?.summary == "YOLO")
    }
}

// MARK: - Summary

struct SessionSettingsSummaryTests {
    @Test func leavesOutADefaultValueAndASwitchThatIsOff() {
        #expect(build(claude).map(\.summary) == ["Opus 5.5", "high", nil, nil])
    }

    @Test func namesASwitchByItsTitleWhileItIsOn() {
        let settings = build(Array(claude.prefix(3)) + [
            select("fast", "Fast mode", "model_config", "on", ["on", "off"]),
            boolean("auto_approve", "Auto-approve tools", true),
        ])
        #expect(settings.map(\.summary) == ["Opus 5.5", "high", nil, "Fast mode", "Auto-approve tools"])
    }

    @Test func alwaysShowsTheModelEvenOneWhoseValueIsDefault() {
        // claude-agent-acp before 0.76 keeps a `default` model row.
        let settings = build([
            select("model", "Model", nil, "default", [opt("default", "Default (recommended)"), opt("opus", "Opus")]),
            select("effort", "Effort", "thought_level", "default", ["default", "max"]),
            select("mode", "Mode", "mode", "plan", ["default", "plan"]),
        ])
        #expect(settings.map(\.summary) == ["Default (recommended)", nil, "plan"])
    }

    @Test func fallsBackToTheFirstValueWhenEverythingWasLeftOut() {
        // Gemini CLI: only its legacy modes, on `default`.
        let settings = build(
            [], modes: [mode("default", "Default", "Prompts for approval"), mode("plan", "Plan", "Read-only mode")],
            currentModeId: "default"
        )
        #expect(settings.map(\.summary) == ["Default"])
    }

    @Test func neverFallsBackOntoASwitch() {
        #expect(build([boolean("auto_approve", "Auto-approve tools", false)]).map(\.summary) == [nil])
    }

    @Test func joinsTheSummaryInOrderAndSpeaksEverySetting() {
        let settings = build(claude)
        #expect(SessionSettings.summaryParts(settings) == ["Opus 5.5", "high"])
        #expect(SessionSettings.accessibilityValue(settings, on: "On", off: "Off")
            == "Model Opus 5.5, Effort high, Mode Manual, Fast mode Off")
    }

    @Test func keepsShortValuesWholeByUnicodeScalarCount() {
        #expect(SessionSettings.isShortSummary("High"))
        #expect(SessionSettings.isShortSummary("12345678"))
        #expect(!SessionSettings.isShortSummary("123456789"))
        #expect(SessionSettings.isShortSummary("智能体设置模式"))
    }
}

// MARK: - Controls

struct SessionSettingsControlTests {
    @Test func makesTheModelAListAndAShortSelectSegmented() throws {
        let settings = build(claude)
        #expect(try choice(settings[0]).presentation == .list)
        #expect(try choice(settings[0]).searchable == false)
        #expect(try choice(settings[1]).presentation == .segmented)
        #expect(try choice(settings[2]).presentation == .segmented)
    }

    @Test func searchesAModelListLongerThanEight() throws {
        let values = (0..<9).map { "m\($0)" }
        let model = try choice(build([select("model", "Model", "model", "m0", values)]).first)
        #expect(model.presentation == .list)
        #expect(model.searchable)
    }

    @Test func turnsAnySelectLongerThanEightIntoASearchableList() throws {
        let eight = (0..<8).map { "v\($0)" }
        #expect(try choice(build([select("a", "A", nil, "v0", eight)]).first).presentation == .segmented)
        #expect(try choice(build([select("a", "A", nil, "v0", eight)]).first).searchable == false)
        let long = try choice(build([select("a", "A", nil, "v0", eight + ["v8"])]).first)
        #expect(long.presentation == .list)
        #expect(long.searchable)
    }

    @Test func readsABooleanOptionAsASwitchThatSendsTrueFalse() throws {
        let setting = try toggle(build([boolean("auto_approve", "Auto", false)]).first)
        #expect(setting == (false, "true", "false"))
    }

    @Test func readsAnOnOffSelectAsASwitchKeepingTheAgentsOwnValues() throws {
        let fast = try toggle(build([select("fast", "Fast", nil, "On", ["Off", "On"])]).first)
        #expect(fast == (true, "On", "Off"))
        let flag = try toggle(build([select("flag", "Flag", nil, "false", ["true", "false"])]).first)
        #expect(flag == (false, "true", "false"))
    }

    @Test func keepsAnOnOffSelectSegmentedWhileItsValueIsNeither() throws {
        // Kiro's thinking toggle reports `default` until a state is set; a switch
        // would claim "off" for it.
        let settings = build([
            select("model", "Model", "model", "k", ["k"]),
            select("thinking", "Thinking", "thought_level", "default", ["on", "off"]),
        ])
        #expect(try choice(settings[1]).presentation == .segmented)
        #expect(settings[1].summary == nil)
    }

    @Test func doesNotReadAThreeValueSelectAsASwitch() {
        let settings = build([select("fast", "Fast", nil, "on", ["on", "off", "auto"])])
        #expect(settings.first.map(isToggle) == false)
    }
}

// MARK: - Values

struct SessionSettingsValueTests {
    @Test func labelsAGroupedModelByItsPrefixStrippedName() throws {
        let setting = build([
            select("model", "Model", "model", "anthropic/claude-opus", ["anthropic/claude-opus", "openai/gpt-4o"]),
        ]).first
        let model = try choice(setting)
        #expect(model.groups.map(\.name) == ["anthropic", "openai"])
        #expect(model.currentLabel == "claude-opus")
        #expect(setting?.summary == "claude-opus")
        // The value itself is never rewritten.
        #expect(model.currentValue == "anthropic/claude-opus")
    }

    @Test func carriesTheCurrentDescriptionAndTheRecommendation() throws {
        let settings = build(claude)
        #expect(try choice(settings[0]).currentDescription == "Best for everyday")
        #expect(try choice(settings[0]).recommendedValue == "opus")
        #expect(try choice(settings[1]).recommendedValue == "medium")
    }

    @Test func fallsBackToTheRawValueWhenItNamesNoOption() throws {
        let setting = build([select("model", "Model", "model", "gone", ["a"])]).first
        #expect(try choice(setting).currentLabel == "gone")
        #expect(setting?.summary == "gone")
    }

    @Test func targetsConfigOptionsById() {
        #expect(build(claude).first?.target == .config(id: "model"))
    }

    @Test func usesTheNativeModelConfigOptionForMiniMax() throws {
        let setting = build([
            select("model", "Model", "model", "m:minimax:MiniMax-M2.7:u",
                   ["m:minimax:MiniMax-M2.7:u", "m:custom%3Aprovider:vendor%2Fmodel:v:fast"]),
        ]).first
        let model = try choice(setting)
        #expect(model.isModel)
        #expect(model.currentValue == "m:minimax:MiniMax-M2.7:u")
        #expect(setting?.target == .config(id: "model"))
        #expect(model.groups.first?.options.map(\.value) == ["m:minimax:MiniMax-M2.7:u", "m:custom%3Aprovider:vendor%2Fmodel:v:fast"])
    }

    @Test func showsAFilteredCurrentModelWithoutOfferingItAgain() throws {
        let model = try choice(build([select("model", "Model", "model", "relay/disabled", ["relay/allowed"])]).first)
        #expect(model.currentLabel == "relay/disabled")
        #expect(model.allOptions.map(\.value) == ["relay/allowed"])
    }
}

// MARK: - The client's selection over the catalog

struct SessionSettingsSelectionTests {
    @Test func laysTheSelectionOverTheCatalogsCurrentValues() {
        let snapshot = AgentOptionsSnapshot(modes: nil, configOptions: claude + [boolean("auto", "Auto", false)])
        let settings = SessionSettings.build(
            snapshot: snapshot, selectedModeId: nil,
            selectedConfig: ["model": "haiku", "mode": "plan", "fast": "on", "auto": "true"],
            modeTitle: "Mode"
        )
        #expect(settings.map(\.summary) == ["Haiku 5.5", "high", "Plan", "Fast mode", "Auto"])
    }

    @Test func showsTheLegacyModesOnlyWithoutRenderableConfigOptions() {
        let modes = SessionModeState(currentModeId: "default", availableModes: [mode("default", "Default"), mode("plan", "Plan")])
        let unknownOnly = SessionConfigOption(id: "x", name: "X", description: nil, category: nil, kind: .unknown(type: "future"))
        let legacy = SessionSettings.build(
            snapshot: AgentOptionsSnapshot(modes: modes, configOptions: [unknownOnly]),
            selectedModeId: "plan", selectedConfig: [:], modeTitle: "Mode"
        )
        #expect(legacy.map(\.key) == ["mode"])
        #expect(legacy.first?.summary == "Plan")

        let suppressed = SessionSettings.build(
            snapshot: AgentOptionsSnapshot(modes: modes, configOptions: claude),
            selectedModeId: "plan", selectedConfig: [:], modeTitle: "Mode"
        )
        #expect(!suppressed.contains { $0.target == .mode })
    }

    @Test func decodesTheRecommendedValueAndToleratesItsAbsence() throws {
        let json = #"""
        {"modes": null, "config_options": [
          {"id": "model", "name": "Model", "description": null, "category": "model",
           "kind": {"type": "select", "current_value": "a", "options": [{"value": "a", "name": "A", "description": null}], "groups": []},
           "recommended_value": "a"},
          {"id": "effort", "name": "Effort", "description": null, "category": "thought_level",
           "kind": {"type": "select", "current_value": "low", "options": [{"value": "low", "name": "Low", "description": null}], "groups": []}}
        ]}
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let snapshot = try decoder.decode(AgentOptionsSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.configOptions.map(\.recommendedValue) == ["a", nil])
    }
}
