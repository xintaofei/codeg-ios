import Foundation
import Testing
@testable import Codeg

// The Kimi panel's reasoning card, ported from the web
// `kimi-code-config-panel.tsx` (its `kimiDraftFromConfig` / `validateKimiDraft`
// reasoning cases and the panel's payload tests), plus the iOS-only rule that
// a field the card didn't change goes out as it is on disk at save time.

/// What the card seeds from: a managed block with thinking on, two levels and a default.
private let thinkingLowHigh = #"""
{"hasManagedBlock":true,"interfaceType":"kimi","key":"sk-saved","modelId":"m",
 "maxContextSize":262144,"capabilities":["thinking"],
 "supportEfforts":["low","high"],"defaultEffort":"high"}
"""#

private func seeded(_ json: String?) -> KimiReasoningDraft {
    KimiReasoningDraft(KimiManagedConfig.parse(json))
}

/// The API-key body the panel builds before the reasoning fields are merged in.
private func apiKeySave() -> UpdateKimiCodeConfigBody {
    UpdateKimiCodeConfigBody(mode: "apikey", interfaceType: "kimi", apiKey: "sk-abc", model: "m")
}

/// Save `draft` from a card seeded with `baseline`, against `onDisk` re-read at
/// save time, and return the JSON that goes over the wire.
private func payload(_ draft: KimiReasoningDraft, baseline: KimiReasoningDraft,
                     onDisk: String?) throws -> [String: Any] {
    let body = try kimiBodyForSave(apiKeySave(), reasoning: KimiReasoningEdit(draft: draft, baseline: baseline),
                                   freshConfigJson: onDisk)
    return try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any] ?? [:]
}

@Suite struct KimiReasoningSeedTests {
    @Test func noCapabilitiesReadsAsOff() {
        // The shape the panel wrote before reasoning existed. kimi reads an
        // absent capabilities array as "allow everything" AND shows no Thinking
        // picker, so it must not read back as reasoning on.
        let d = seeded(#"{"interfaceType":"kimi","modelId":"m"}"#)
        #expect(d == KimiReasoningDraft())
        #expect(!d.reasoningEnabled)
        #expect(!d.alwaysThinking)
        #expect(d.supportEfforts.isEmpty)
        #expect(d.defaultEffort == "")
    }

    @Test func eitherThinkingCapabilityReadsAsOn() {
        let thinking = seeded(#"{"capabilities":["thinking","image_in"]}"#)
        #expect(thinking.reasoningEnabled && !thinking.alwaysThinking)
        let always = seeded(#"{"capabilities":["always_thinking"]}"#)
        #expect(always.reasoningEnabled && always.alwaysThinking)
    }

    @Test func theLevelsAndDefaultRoundTrip() {
        let d = seeded(thinkingLowHigh)
        #expect(d.supportEfforts == ["low", "high"])
        #expect(d.defaultEffort == "high")
    }

    @Test func equalityIsByValue() {
        // A freshly seeded card must never read as edited.
        #expect(seeded(thinkingLowHigh) == seeded(thinkingLowHigh))
        let base = seeded(thinkingLowHigh)
        var removed = base; removed.supportEfforts = ["low"]
        var reordered = base; reordered.supportEfforts = ["high", "low"]
        #expect(base != removed)
        #expect(base != reordered)
    }
}

@Suite struct KimiReasoningCardTests {
    @Test func theChipsAreTheCommonLevelsThenAnySavedCustomOne() {
        #expect(KimiReasoningDraft().effortChoices == ["minimal", "low", "medium", "high", "xhigh", "max"])
        let custom = KimiReasoningDraft(reasoningEnabled: true, supportEfforts: ["ultra", "low"])
        #expect(custom.effortChoices == ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"])
    }

    @Test func switchingLevelsOnKeepsChipOrder() {
        var d = KimiReasoningDraft(reasoningEnabled: true)
        d.toggleEffort("high")
        d.toggleEffort("low")
        #expect(d.supportEfforts == ["low", "high"])
        d.toggleEffort("high")
        #expect(d.supportEfforts == ["low"])
    }

    @Test func switchingTheDefaultsLevelOffDropsTheDefault() {
        var d = seeded(thinkingLowHigh)
        d.toggleEffort("low")
        #expect(d.defaultEffort == "high", "the default's own level is still offered")
        d.toggleEffort("high")
        #expect(d.supportEfforts.isEmpty)
        #expect(d.defaultEffort == "")
    }

    @Test func aCustomLevelIsTrimmedAndAddedOnce() {
        var d = KimiReasoningDraft(reasoningEnabled: true, supportEfforts: ["low"])
        d.addCustomEffort("  ultra ")
        d.addCustomEffort("ultra")
        d.addCustomEffort("   ")
        d.addCustomEffort("low")
        #expect(d.supportEfforts == ["low", "ultra"])
        // A custom chip switched off is gone, like the web's.
        d.toggleEffort("ultra")
        #expect(!d.effortChoices.contains("ultra"))
    }

    @Test func aDefaultOutsideTheOfferedLevelsBlocksTheSave() {
        // kimi silently clamps an unlisted default to the middle entry, so the
        // composer would open on a level the user never picked.
        let unlisted = KimiReasoningDraft(reasoningEnabled: true, supportEfforts: ["low", "high"], defaultEffort: "max")
        #expect(unlisted.defaultEffortIsUnlisted)
        let listed = KimiReasoningDraft(reasoningEnabled: true, supportEfforts: ["low", "high"], defaultEffort: "high")
        #expect(!listed.defaultEffortIsUnlisted)
        let auto = KimiReasoningDraft(reasoningEnabled: true, supportEfforts: ["low", "high"])
        #expect(!auto.defaultEffortIsUnlisted)
    }

    @Test func theDefaultIsIgnoredWhileReasoningIsOff() {
        let off = KimiReasoningDraft(reasoningEnabled: false, defaultEffort: "max")
        #expect(!off.defaultEffortIsUnlisted)
        let offWithLevels = KimiReasoningDraft(reasoningEnabled: false, supportEfforts: ["low"], defaultEffort: "max")
        #expect(!offWithLevels.defaultEffortIsUnlisted)
    }
}

@Suite struct KimiReasoningPayloadTests {
    @Test func reasoningStaysOutOfThePayloadUntilSwitchedOn() throws {
        // Off sends no levels, so the backend omits `capabilities` and kimi
        // keeps its permissive default.
        let fresh = seeded(nil)
        let json = try payload(fresh, baseline: fresh, onDisk: nil)
        #expect(json["reasoningEnabled"] as? Bool == false)
        #expect(json["alwaysThinking"] as? Bool == false)
        #expect(json["supportEfforts"] as? [String] == [])
        #expect(json["defaultEffort"] == nil)
    }

    @Test func theChosenLevelsGoOutOnceSwitchedOn() throws {
        let fresh = seeded(nil)
        var d = fresh
        d.reasoningEnabled = true
        d.toggleEffort("low")
        d.toggleEffort("high")
        let json = try payload(d, baseline: fresh, onDisk: nil)
        #expect(json["reasoningEnabled"] as? Bool == true)
        #expect(json["alwaysThinking"] as? Bool == false)
        #expect(json["supportEfforts"] as? [String] == ["low", "high"])
        #expect(json["apiKey"] as? String == "sk-abc")
    }

    @Test func aDefaultIsDroppedWithItsChip() throws {
        let base = seeded(thinkingLowHigh)
        var d = base
        d.toggleEffort("high")
        let json = try payload(d, baseline: base, onDisk: thinkingLowHigh)
        #expect(json["supportEfforts"] as? [String] == ["low"])
        #expect(json["defaultEffort"] as? String == "")
    }

    @Test func alwaysThinkingGoesOutOnlyWithReasoningOn() throws {
        let base = seeded(thinkingLowHigh)
        var always = base
        always.alwaysThinking = true
        let on = try payload(always, baseline: base, onDisk: thinkingLowHigh)
        #expect(on["alwaysThinking"] as? Bool == true)

        // Switching reasoning off sends no levels or default either, though the
        // card still holds them for switching it back on.
        var off = always
        off.reasoningEnabled = false
        let json = try payload(off, baseline: base, onDisk: thinkingLowHigh)
        #expect(json["reasoningEnabled"] as? Bool == false)
        #expect(json["alwaysThinking"] as? Bool == false)
        #expect(json["supportEfforts"] as? [String] == [])
        #expect(json["defaultEffort"] == nil)
    }

    @Test func anUntouchedCardSendsWhatIsOnDiskNow() throws {
        // Seeded with thinking off, but turned on with levels elsewhere before
        // the save: an untouched card must not switch it back off.
        let base = seeded(nil)
        let json = try payload(base, baseline: base, onDisk: thinkingLowHigh)
        #expect(json["reasoningEnabled"] as? Bool == true)
        #expect(json["supportEfforts"] as? [String] == ["low", "high"])
        #expect(json["defaultEffort"] as? String == "high")
    }

    @Test func onlyTheEditedFieldsOverrideTheDisk() throws {
        // The user only changed the default; meanwhile another client switched
        // to always-thinking and added a level.
        let base = seeded(thinkingLowHigh)
        var d = base
        d.defaultEffort = "low"
        let onDisk = #"{"capabilities":["always_thinking"],"supportEfforts":["low","medium","high"],"defaultEffort":"high"}"#
        let json = try payload(d, baseline: base, onDisk: onDisk)
        #expect(json["defaultEffort"] as? String == "low")
        #expect(json["supportEfforts"] as? [String] == ["low", "medium", "high"])
        #expect(json["alwaysThinking"] as? Bool == true)
        #expect(json["reasoningEnabled"] as? Bool == true)
    }

    @Test func anEditUndoneCountsAsUntouched() throws {
        let base = seeded(thinkingLowHigh)
        var d = base
        d.toggleEffort("max")
        d.toggleEffort("max")
        #expect(d == base)
        let onDisk = #"{"capabilities":["thinking"],"supportEfforts":["medium"]}"#
        let json = try payload(d, baseline: base, onDisk: onDisk)
        #expect(json["supportEfforts"] as? [String] == ["medium"])
    }

    @Test func loginAndRawIgnoreTheCard() throws {
        var d = seeded(nil)
        d.reasoningEnabled = true
        let edit = KimiReasoningEdit(draft: d, baseline: seeded(nil))
        let login = try kimiBodyForSave(UpdateKimiCodeConfigBody(mode: "login"), reasoning: edit, freshConfigJson: nil)
        #expect(login.reasoningEnabled == nil)
        #expect(login.supportEfforts == nil)
        let raw = try kimiBodyForSave(UpdateKimiCodeConfigBody(mode: "raw", rawConfigToml: "x = 1"),
                                      reasoning: edit, freshConfigJson: nil)
        #expect(raw.reasoningEnabled == nil)
        #expect(raw.rawConfigToml == "x = 1")
    }
}

/// A default and its level list resolved from different sources (one edited
/// here, the other carried from disk) that no longer agree: the backend would
/// drop the default and report success, so no body is built — and so no write.
@Suite struct KimiReasoningConflictTests {
    private func save(_ draft: KimiReasoningDraft, baseline: KimiReasoningDraft, onDisk: String) throws {
        _ = try kimiBodyForSave(apiKeySave(), reasoning: KimiReasoningEdit(draft: draft, baseline: baseline),
                                freshConfigJson: onDisk)
    }

    @Test func aDefaultPickedHereWhoseLevelWentElsewhere() {
        let base = seeded(thinkingLowHigh)
        var d = base
        d.defaultEffort = "low"
        #expect(throws: KimiReasoningConflict()) {
            try save(d, baseline: base, onDisk: #"{"capabilities":["thinking"],"supportEfforts":["high"]}"#)
        }
        // Every level cleared elsewhere drops it just the same.
        #expect(throws: KimiReasoningConflict()) {
            try save(d, baseline: base, onDisk: #"{"capabilities":["thinking"]}"#)
        }
    }

    @Test func aLevelRemovedHereThatIsNowTheDefaultElsewhere() {
        let base = seeded(thinkingLowHigh)
        var d = base
        d.toggleEffort("low")
        #expect(d.defaultEffort == "high", "the card's own default is untouched")
        #expect(throws: KimiReasoningConflict()) {
            try save(d, baseline: base,
                     onDisk: #"{"capabilities":["thinking"],"supportEfforts":["low","high"],"defaultEffort":"low"}"#)
        }
    }

    @Test func aPairWhollyFromOneSourceGoesThrough() throws {
        // Both edited here: the card's own, validated choice wins.
        let base = seeded(thinkingLowHigh)
        var both = base
        both.toggleEffort("max")
        both.defaultEffort = "max"
        let json = try payload(both, baseline: base, onDisk: #"{"capabilities":["thinking"],"supportEfforts":["low"]}"#)
        #expect(json["supportEfforts"] as? [String] == ["low", "high", "max"])
        #expect(json["defaultEffort"] as? String == "max")

        // Both untouched: carried as on disk, even a hand-written mismatch the
        // backend tidies anyway (as before the card existed).
        let handWritten = #"{"capabilities":["thinking"],"supportEfforts":["low"],"defaultEffort":"max"}"#
        let carried = try payload(base, baseline: base, onDisk: handWritten)
        #expect(carried["defaultEffort"] as? String == "max")
    }

    @Test func reasoningOffHasNoDefaultToLose() throws {
        let base = seeded(thinkingLowHigh)
        var d = base
        d.defaultEffort = "low"
        d.reasoningEnabled = false
        let json = try payload(d, baseline: base, onDisk: #"{"capabilities":["thinking"],"supportEfforts":["high"]}"#)
        #expect(json["reasoningEnabled"] as? Bool == false)
        #expect(json["defaultEffort"] == nil)
    }
}
